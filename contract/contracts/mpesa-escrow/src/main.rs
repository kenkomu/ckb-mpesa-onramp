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
// Lock args (124 bytes, set once at cell-creation time by the seller):
//   witness_address:     [u8; 20]  -- the trusted Verifier's Ethereum-style address
//   recipient_hash:      [u8; 32]  -- hash(seller's M-Pesa number)
//   amount:               u64 LE   -- the exact KES amount (minor units) expected
//   registry_type_hash:  [u8; 32]  -- calc_script_hash() of the live ClaimsRegistry
//                                     cell's type script this deployment trusts
//   offer_guard_type_hash: [u8; 32] -- calc_script_hash() of the OfferGuard Type
//                                     Script this deployment trusts to have
//                                     checked seller-ownership at mint time
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
// Expiry, clear and reclaim (all driven by CKB's `since` field, because a
// script cannot read the wall clock): an absolute-timestamp `since` on the
// escrow input proves "now >= that time" at commit, nothing more. So:
//   - Lock args also carry `seller_lock_hash` and an offer `deadline`.
//   - Reservation data is 40 bytes: reserved_by(32) || reserved_until(u64 LE).
//   - RESERVE: reserved_until must equal since + RESERVATION_WINDOW_SECS, and
//     since must be < deadline. A reserver can't claim a longer window than
//     the chain's real time allows (a future `since` just delays the tx).
//   - CLEAR: anyone may reopen an expired reservation (since >= reserved_until),
//     same cell, empty data. A late CLAIM by the original reserver is still
//     allowed until someone clears -- paying late is not punished.
//   - RECLAIM: the seller (their lock hash is an input) takes the CKB back
//     once since >= deadline (and >= reserved_until if reserved).
//   - CONFIRM: until real Safaricom payment proofs exist, the seller must
//     confirm receipt before a claim can succeed. The seller (their lock
//     hash is an input) turns the 40-byte reservation into a 41-byte
//     "confirmed" one (same data + 0x01). CLAIM only works on confirmed
//     cells, so nobody can claim without the seller's say-so. Trade-off,
//     stated plainly: a seller can withhold confirmation (the same weakness
//     as Binance P2P) -- real proofs are meant to remove that step.
//   - RESERVE and CLEAR must not shrink the cell's capacity or change its
//     type script -- otherwise anyone could "reserve" an offer and pocket
//     the escrowed CKB in the same transaction.
//
// Check 5 (seller-ownership, enforced at MINT, cross-checked here at
// CLAIM): a Lock Script only ever executes when its cell is being SPENT --
// never when it's merely being created as an output -- so this script
// itself has no way to inspect or constrain how its own escrow cell was
// created. Seller-ownership is instead enforced by a separate Type Script,
// `contracts/offer-guard` (which DOES run on both sides of a transaction),
// attached to the escrow cell at mint time: it requires an ownership
// signature there before allowing the cell to exist at all, then allows it
// to persist across transfers unchanged (mint/transfer pattern, same shape
// as claims-registry). This script's own job is just to make sure the
// escrow cell it's about to release actually carries that Type Script: the
// CLAIM path checks `load_cell_type_hash(0, GroupInput) ==
// Some(offer_guard_type_hash)`. Since OfferGuard's own transfer rule can't
// change a live cell's recipient_hash/witness_address (Type Script groups
// are keyed by the exact script hash, args included), any escrow cell
// still carrying this type hash necessarily traces back to a mint
// OfferGuard approved.

use alloc::vec::Vec;

use ckb_std::ckb_constants::Source;
use ckb_std::ckb_types::prelude::*;
use ckb_std::high_level::{
    QueryIter, load_cell_capacity, load_cell_data, load_cell_lock_hash, load_cell_type_hash,
    load_input_since, load_script, load_witness_args,
};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use sha3::{Digest, Keccak256};

const ARGS_LEN: usize = 164;
const WITNESS_LEN: usize = 137;
const CLAIM_MSG_LEN: usize = 72; // tx_id_hash(32) + recipient_hash(32) + amount(8)
const HASH_LEN: usize = 32;
const RESERVATION_LEN: usize = 40; // reserved_by_lock_hash(32) + reserved_until(u64 LE)
const CONFIRMED_LEN: usize = 41; // reservation(40) + 0x01
const RESERVATION_WINDOW_SECS: u64 = 20 * 60;
// since: bit 63 = relative flag, bits 62..61 = metric. Absolute timestamp = 0b010.
const SINCE_ABSOLUTE_TIMESTAMP: u64 = 0b010;
const SINCE_VALUE_MASK: u64 = 0x00ff_ffff_ffff_ffff;

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
const ERROR_OFFER_GUARD_MISSING: i8 = 17;
const ERROR_SINCE_INVALID: i8 = 18;
const ERROR_OFFER_EXPIRED: i8 = 19;
const ERROR_BAD_RESERVATION_WINDOW: i8 = 20;
const ERROR_CELL_NOT_PRESERVED: i8 = 21;
const ERROR_TOO_EARLY: i8 = 22;
const ERROR_SELLER_NOT_PRESENT: i8 = 23;
const ERROR_NOT_CONFIRMED: i8 = 24;

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
    let expected_offer_guard_type_hash: [u8; 32] = args[92..124].try_into().unwrap();
    let seller_lock_hash: [u8; 32] = args[124..156].try_into().unwrap();
    let deadline = u64::from_le_bytes(args[156..164].try_into().unwrap());

    let input_data = match load_cell_data(0, Source::GroupInput) {
        Ok(data) => data,
        Err(_) => return ERROR_CELL_DATA_MISSING,
    };

    let own_script_hash: [u8; 32] = script.calc_script_hash().unpack();
    // Lock scripts never get a "GroupOutput" the way Type scripts do, so a
    // continuation cell is found explicitly: the Output whose lock hash is
    // this script's own hash.
    let continuation = QueryIter::new(load_cell_lock_hash, Source::Output)
        .position(|hash| hash == own_script_hash);
    let has_claim_witness = claim_witness_present();

    match (input_data.len(), has_claim_witness, continuation) {
        (0, _, Some(out)) => return reserve(out, deadline),
        (RESERVATION_LEN, false, Some(out)) => {
            return match load_cell_data(out, Source::Output) {
                Ok(data) if data.is_empty() => clear(out, &input_data),
                Ok(data) if data.len() == CONFIRMED_LEN => {
                    confirm(out, &input_data, &data, &seller_lock_hash)
                }
                _ => ERROR_UNSUPPORTED_STRUCTURE,
            }
        }
        (0, _, None) => return reclaim(None, deadline, &seller_lock_hash),
        (RESERVATION_LEN, false, None) => {
            return reclaim(Some(&input_data), deadline, &seller_lock_hash)
        }
        (RESERVATION_LEN, true, _) => return ERROR_NOT_CONFIRMED,
        (CONFIRMED_LEN, true, _) => {}
        _ => return ERROR_UNSUPPORTED_STRUCTURE,
    }

    // Anything left is a CLAIM: a seller-confirmed reservation being spent.
    let reserved_by_lock_hash = &input_data[..32];

    // Check 5 (cross-check): the escrow cell actually being spent must
    // carry the trusted OfferGuard Type Script -- see the module doc
    // comment for why this is checked here rather than at mint.
    let offer_guard_present = load_cell_type_hash(0, Source::GroupInput)
        .ok()
        .flatten()
        .map(|hash| hash == expected_offer_guard_type_hash)
        .unwrap_or(false);
    if !offer_guard_present {
        return ERROR_OFFER_GUARD_MISSING;
    }

    let witness_args = match load_witness_args(0, Source::GroupInput) {
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

/// Absolute-timestamp `since` (seconds) of the escrow input, if it has one.
fn absolute_since_secs() -> Option<u64> {
    let since = load_input_since(0, Source::GroupInput).ok()?;
    if since >> 61 != SINCE_ABSOLUTE_TIMESTAMP {
        return None;
    }
    Some(since & SINCE_VALUE_MASK)
}

fn claim_witness_present() -> bool {
    match load_witness_args(0, Source::GroupInput) {
        Ok(args) => match args.lock().to_opt() {
            Some(field) => Unpack::<Vec<u8>>::unpack(&field).len() == WITNESS_LEN,
            None => false,
        },
        Err(_) => false,
    }
}

/// The continuation output must keep (at least) the escrowed capacity and
/// the same type script, or the transition could siphon off the funds.
fn cell_preserved(out: usize) -> bool {
    let cap_in = load_cell_capacity(0, Source::GroupInput);
    let cap_out = load_cell_capacity(out, Source::Output);
    let type_in = load_cell_type_hash(0, Source::GroupInput);
    let type_out = load_cell_type_hash(out, Source::Output);
    matches!((cap_in, cap_out), (Ok(i), Ok(o)) if o >= i) && type_in.ok() == type_out.ok()
}

fn reserve(out: usize, deadline: u64) -> i8 {
    let since = match absolute_since_secs() {
        Some(since) => since,
        None => return ERROR_SINCE_INVALID,
    };
    if since >= deadline {
        return ERROR_OFFER_EXPIRED;
    }
    let data = match load_cell_data(out, Source::Output) {
        Ok(data) if data.len() == RESERVATION_LEN => data,
        _ => return ERROR_UNSUPPORTED_STRUCTURE,
    };
    let until = u64::from_le_bytes(data[32..40].try_into().unwrap());
    if until != since.saturating_add(RESERVATION_WINDOW_SECS) {
        return ERROR_BAD_RESERVATION_WINDOW;
    }
    if !cell_preserved(out) {
        return ERROR_CELL_NOT_PRESERVED;
    }
    0
}

fn clear(out: usize, input_data: &[u8]) -> i8 {
    let since = match absolute_since_secs() {
        Some(since) => since,
        None => return ERROR_SINCE_INVALID,
    };
    let until = u64::from_le_bytes(input_data[32..40].try_into().unwrap());
    if since < until {
        return ERROR_TOO_EARLY;
    }
    match load_cell_data(out, Source::Output) {
        Ok(data) if data.is_empty() => {}
        _ => return ERROR_UNSUPPORTED_STRUCTURE,
    }
    if !cell_preserved(out) {
        return ERROR_CELL_NOT_PRESERVED;
    }
    0
}

fn confirm(out: usize, input_data: &[u8], output_data: &[u8], seller_lock_hash: &[u8; 32]) -> i8 {
    if output_data[..RESERVATION_LEN] != *input_data || output_data[RESERVATION_LEN] != 1 {
        return ERROR_UNSUPPORTED_STRUCTURE;
    }
    let seller_present =
        QueryIter::new(load_cell_lock_hash, Source::Input).any(|hash| &hash == seller_lock_hash);
    if !seller_present {
        return ERROR_SELLER_NOT_PRESENT;
    }
    if !cell_preserved(out) {
        return ERROR_CELL_NOT_PRESERVED;
    }
    0
}

fn reclaim(reservation: Option<&[u8]>, deadline: u64, seller_lock_hash: &[u8; 32]) -> i8 {
    let since = match absolute_since_secs() {
        Some(since) => since,
        None => return ERROR_SINCE_INVALID,
    };
    let mut not_before = deadline;
    if let Some(data) = reservation {
        let until = u64::from_le_bytes(data[32..40].try_into().unwrap());
        not_before = not_before.max(until);
    }
    if since < not_before {
        return ERROR_TOO_EARLY;
    }
    let seller_present =
        QueryIter::new(load_cell_lock_hash, Source::Input).any(|hash| &hash == seller_lock_hash);
    if !seller_present {
        return ERROR_SELLER_NOT_PRESENT;
    }
    0
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
