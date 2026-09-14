#![cfg_attr(not(any(feature = "library", test)), no_std)]
#![cfg_attr(not(test), no_main)]

#[cfg(any(feature = "library", test))]
extern crate alloc;

#[cfg(not(any(feature = "library", test)))]
ckb_std::entry!(program_entry);
#[cfg(not(any(feature = "library", test)))]
// By default, the following heap configuration is used:
// * 16KB fixed heap
// * 1.2MB(rounded up to be 16-byte aligned) dynamic heap
// * Minimal memory block in dynamic heap is 64 bytes
// For more details, please refer to ckb-std's default_alloc macro
// and the buddy-alloc alloc implementation.
ckb_std::default_alloc!(16384, 1258306, 64);

// MpesaEscrow -- Bitshada's trustless M-Pesa<->CKB escrow Lock Script.
//
// This is the first, incremental slice of the six-check design in the Bitshada
// plan: attestor signature verification (check 2) and claim-field matching
// (check 3). Nullifier/replay protection, the reservation check, the
// seller-ownership check, and the deadline check are deliberately not here yet
// -- this slice exists to de-risk the genuinely novel part (recoverable
// secp256k1 signature verification in a no_std RISC-V script) before adding the
// remaining checks, which are all more standard CKB patterns with direct
// precedent elsewhere in this project.
//
// Trust model (explicit, not hidden): this script trusts exactly one
// Ethereum-style address, embedded in its own lock args, to have signed the
// claim. That address belongs to Ken's own TLSNotary Verifier -- the same
// party that already had to co-verify the real MPC-TLS session to produce a
// TLSNotary Attestation/Presentation in the first place. Re-verifying that
// full presentation (Merkle-committed transcript, certificate chain, etc.)
// on-chain is out of scope for this grant; instead, after verifying a real
// presentation off-chain, the Verifier signs a small, fixed-shape claim
// summarizing just the fields this contract needs, using the same
// SECP256K1ETH scheme TLSNotary's own attestation module already supports
// (crates/attestation/src/signing.rs) -- secp256k1 with Keccak-256 hashing,
// a recoverable `r || s || v` signature matching Solidity's ecrecover().
//
// Lock args (92 bytes, set once at cell-creation time by the seller):
//   witness_address:   [u8; 20]  -- the trusted Verifier's Ethereum-style address
//   recipient_hash:    [u8; 32]  -- hash(seller's M-Pesa number)
//   amount:            u64 LE    -- the exact KES amount (minor units) expected
//   registry_type_hash: [u8; 32] -- calc_script_hash() of the live ClaimsRegistry
//                                   cell's type script this deployment trusts
//
// Witness (WitnessArgs.lock field, 137 bytes, provided by the buyer to unlock):
//   tx_id_hash:        [u8; 32]  -- hash of the real M-Pesa transaction ID
//   claim_recipient_hash: [u8; 32]
//   claim_amount:      u64 LE
//   signature:         [u8; 65]  -- r || s || v over Keccak256(tx_id_hash || claim_recipient_hash || claim_amount)
//
// Check 1 (nullifier): after everything below passes, this script also
// requires that `tx_id_hash` is the exact hash being freshly appended, in
// THIS transaction, to a live output cell whose type script hash matches
// `registry_type_hash` -- see contracts/claims-registry. That contract's own
// rules (append-only, no duplicates) are what actually make replay
// impossible; this script's only job is to make sure the claim it just
// verified is the SAME tx_id being registered, not some other one.
//
// Check 4 (reservation, the ghosting-prevention half only -- see the module
// note below on what's deferred): the escrow cell's own DATA (not its args,
// which are fixed forever) carries reservation state -- empty when open, or
// exactly one 32-byte lock hash when reserved. Two transaction shapes are
// recognized by GroupInput data length, plus (RESERVE only) an explicit
// Output-side search: CKB Lock scripts never get a "GroupOutput" the way
// Type scripts do -- only Type-script groups get output_indices populated
// (see ckb-script's TxData::new) -- so there is no automatic notion of
// "this input's corresponding output." RESERVE instead searches Source::
// Output for the one cell whose lock hash matches this script's own hash.
//   RESERVE:  GroupInput data is empty, and the Output cell sharing this
//             script's own lock hash carries 32 bytes of data -- anyone may
//             reserve an open offer (this is deliberately unauthorized; the
//             reservation window bounds the cost of ghosting to wasted
//             time, never money, matching the Bitshada plan's own
//             "Non-payment and abuse cases" reasoning).
//   CLAIM:    GroupInput data is 32 bytes (an active reservation) and a
//             137-byte claim witness is present -- on top of every check
//             above, the reserved lock hash must match some OTHER input's
//             lock hash in this same transaction, proving the claimant is
//             the same party who reserved it, not a different buyer racing
//             in with someone else's valid-looking claim.
//
// Deliberately NOT implemented yet: reservation expiry / reopening an
// abandoned offer, and the seller's own overall deadline reclaim path --
// both need CKB's `since` timelock mechanism, out of scope for this
// increment. Right now a reservation, once made, is permanent until
// claimed; that's an honest, named MVP gap, not a hidden one.

use alloc::vec::Vec;

use ckb_std::ckb_constants::Source;
use ckb_std::ckb_types::prelude::*;
use ckb_std::high_level::{
    QueryIter, load_cell_data, load_cell_lock_hash, load_cell_type_hash, load_script,
    load_witness_args,
};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use sha3::{Digest, Keccak256};

const ARGS_LEN: usize = 92;
const WITNESS_LEN: usize = 137;
const CLAIM_MSG_LEN: usize = 72; // tx_id_hash(32) + recipient_hash(32) + amount(8)
const HASH_LEN: usize = 32;
const RESERVATION_LEN: usize = 32; // reserved_by_lock_hash

const ERROR_ARGS_LEN: i8 = 4;
const ERROR_WITNESS_MISSING: i8 = 5;
const ERROR_WITNESS_LEN: i8 = 6;
const ERROR_SIGNATURE_MALFORMED: i8 = 7;
const ERROR_RECOVERY_FAILED: i8 = 8;
const ERROR_WITNESS_ADDRESS_MISMATCH: i8 = 9;
const ERROR_RECIPIENT_MISMATCH: i8 = 10;
const ERROR_AMOUNT_MISMATCH: i8 = 11;
const ERROR_REGISTRY_NOT_FOUND: i8 = 12;
const ERROR_REGISTRY_NOT_REGISTERING_THIS_CLAIM: i8 = 13;
const ERROR_CELL_DATA_MISSING: i8 = 14;
const ERROR_UNSUPPORTED_STRUCTURE: i8 = 15;
const ERROR_NOT_RESERVED_BY_CLAIMANT: i8 = 16;

pub fn program_entry() -> i8 {
    let script = match load_script() {
        Ok(script) => script,
        Err(_) => return ERROR_ARGS_LEN,
    };
    let args: Vec<u8> = script.args().unpack();
    if args.len() != ARGS_LEN {
        return ERROR_ARGS_LEN;
    }
    let expected_witness_address = &args[0..20];
    let expected_recipient_hash = &args[20..52];
    let expected_amount = i64::from_le_bytes(args[52..60].try_into().unwrap());
    let expected_registry_type_hash = &args[60..92];

    let input_data = match load_cell_data(0, Source::GroupInput) {
        Ok(data) => data,
        Err(_) => return ERROR_CELL_DATA_MISSING,
    };

    // RESERVE: open offer -> reserved. No claim witness involved at all.
    //
    // Lock scripts never get a "GroupOutput" in the way Type scripts do --
    // CKB only populates output_indices for Type-script groups (an output
    // cell has no independent notion of "being unlocked" the way an input
    // does), so a Lock script has no built-in correspondence to any output.
    // The RESERVE transition therefore finds its own continuation cell
    // explicitly: the (only) Output whose lock hash matches this script's
    // own hash.
    if input_data.is_empty() {
        let own_script_hash: [u8; 32] = script.calc_script_hash().unpack();
        let output_index =
            QueryIter::new(load_cell_lock_hash, Source::Output).position(|hash| hash == own_script_hash);
        let output_data = match output_index {
            Some(index) => load_cell_data(index, Source::Output).ok(),
            None => None,
        };
        return match output_data {
            Some(data) if data.len() == RESERVATION_LEN => 0,
            _ => ERROR_UNSUPPORTED_STRUCTURE,
        };
    }

    // Anything else must be a CLAIM: an active reservation being spent.
    if input_data.len() != RESERVATION_LEN {
        return ERROR_UNSUPPORTED_STRUCTURE;
    }
    let reserved_by_lock_hash = &input_data[..];

    let witness_args = match load_witness_args(0, ckb_std::ckb_constants::Source::GroupInput) {
        Ok(witness_args) => witness_args,
        Err(_) => return ERROR_WITNESS_MISSING,
    };
    let lock_field = match witness_args.lock().to_opt() {
        Some(field) => field,
        None => return ERROR_WITNESS_MISSING,
    };
    let witness: Vec<u8> = lock_field.unpack();
    if witness.len() != WITNESS_LEN {
        return ERROR_WITNESS_LEN;
    }

    // The claimant must be the same party who holds the reservation: some
    // OTHER input in this transaction (e.g. the buyer's own funding input)
    // must already be locked by the reserved lock hash. Same "authorization
    // delegation" pattern as SUDT's owner-mode check (Week 9).
    let claimant_present = QueryIter::new(load_cell_lock_hash, Source::Input)
        .any(|hash| hash == reserved_by_lock_hash);
    if !claimant_present {
        return ERROR_NOT_RESERVED_BY_CLAIMANT;
    }

    let tx_id_hash = &witness[0..32];
    let claim_recipient_hash = &witness[32..64];
    let claim_amount_bytes = &witness[64..72];
    let signature_bytes = &witness[72..137];

    // Reconstruct exactly what the Verifier signed.
    let mut message = [0u8; CLAIM_MSG_LEN];
    message[0..32].copy_from_slice(tx_id_hash);
    message[32..64].copy_from_slice(claim_recipient_hash);
    message[64..72].copy_from_slice(claim_amount_bytes);

    let recovered_address = match recover_eth_address(&message, signature_bytes) {
        Ok(address) => address,
        Err(code) => return code,
    };

    if recovered_address != expected_witness_address {
        return ERROR_WITNESS_ADDRESS_MISMATCH;
    }
    if claim_recipient_hash != expected_recipient_hash {
        return ERROR_RECIPIENT_MISMATCH;
    }
    let claim_amount = i64::from_le_bytes(claim_amount_bytes.try_into().unwrap());
    if claim_amount != expected_amount {
        return ERROR_AMOUNT_MISMATCH;
    }

    // Check 1: this exact tx_id must be the one being freshly registered in
    // the trusted ClaimsRegistry cell, in this same transaction.
    match find_registry_update(expected_registry_type_hash) {
        Some(newly_registered_hash) if newly_registered_hash == tx_id_hash => 0,
        Some(_) => ERROR_REGISTRY_NOT_REGISTERING_THIS_CLAIM,
        None => ERROR_REGISTRY_NOT_FOUND,
    }
}

/// Scans transaction outputs for a cell whose type script hash matches
/// `registry_type_hash`, and returns the last 32 bytes of its data -- the
/// hash ClaimsRegistry's own append-only rule requires to be the newly
/// appended one. Returns None if no such output exists.
fn find_registry_update(registry_type_hash: &[u8]) -> Option<Vec<u8>> {
    let expected: [u8; HASH_LEN] = registry_type_hash.try_into().ok()?;
    let index = QueryIter::new(load_cell_type_hash, Source::Output)
        .position(|hash| hash == Some(expected))?;
    let data = load_cell_data(index, Source::Output).ok()?;
    if data.len() < HASH_LEN {
        return None;
    }
    Some(data[data.len() - HASH_LEN..].to_vec())
}

/// Recovers the Ethereum-style address (last 20 bytes of Keccak256 of the
/// uncompressed public key) that produced `signature` (r || s || v, 65 bytes)
/// over Keccak256(message) -- the exact scheme TLSNotary's own
/// `Secp256k1EthSigner` uses (crates/attestation/src/signing.rs).
fn recover_eth_address(message: &[u8], signature: &[u8]) -> Result<[u8; 20], i8> {
    if signature.len() != 65 {
        return Err(ERROR_SIGNATURE_MALFORMED);
    }

    let sig = Signature::from_slice(&signature[..64]).map_err(|_| ERROR_SIGNATURE_MALFORMED)?;
    let v = signature[64];
    if v < 27 {
        return Err(ERROR_SIGNATURE_MALFORMED);
    }
    let recid = RecoveryId::from_byte(v - 27).ok_or(ERROR_SIGNATURE_MALFORMED)?;

    let mut hasher = Keccak256::new();
    hasher.update(message);
    let digest = hasher.finalize();

    let recovered_key = VerifyingKey::recover_from_prehash(&digest, &sig, recid)
        .map_err(|_| ERROR_RECOVERY_FAILED)?;

    // Uncompressed SEC1 point is 0x04 || X(32) || Y(32); Ethereum addresses
    // Keccak256-hash just the X || Y part (65 bytes minus the leading 0x04),
    // then take the last 20 bytes.
    let encoded = recovered_key.to_encoded_point(false);
    let pubkey_bytes = &encoded.as_bytes()[1..];

    let mut addr_hasher = Keccak256::new();
    addr_hasher.update(pubkey_bytes);
    let addr_digest = addr_hasher.finalize();

    let mut address = [0u8; 20];
    address.copy_from_slice(&addr_digest[12..32]);
    Ok(address)
}
