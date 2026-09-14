#![cfg_attr(not(any(feature = "library", test)), no_std)]
#![cfg_attr(not(test), no_main)]

#[cfg(any(feature = "library", test))]
extern crate alloc;

#[cfg(not(any(feature = "library", test)))]
ckb_std::entry!(program_entry);
#[cfg(not(any(feature = "library", test)))]
ckb_std::default_alloc!(16384, 1258306, 64);

// OfferGuard -- Bitshada's seller-ownership check (check 5), as a Type
// Script.
//
// Why this has to be a Type Script, not more mpesa-escrow Lock Script code:
// a CKB Lock Script only ever executes when its cell is being SPENT (used
// as an input, to authorize releasing it) -- never when the cell is merely
// being CREATED as an output. There is no on-chain hook at all for "run
// some check when this cell is minted" via a Lock Script; a first attempt
// at this check tried exactly that and the negative tests silently passed,
// because the escrow's own lock code never ran during a mint-only
// transaction at all. Type Scripts don't have this limitation -- CKB runs
// a Type Script once per script-hash group found on EITHER side of a
// transaction (inputs and outputs both), which is exactly the hook needed
// here.
//
// Args (52 bytes, chosen once by the seller when creating an offer):
//   witness_address: [u8; 20] -- the trusted Verifier's Ethereum-style
//                                 address (same Verifier mpesa-escrow's
//                                 own args trust, in practice)
//   recipient_hash:  [u8; 32] -- hash(seller's M-Pesa number)
//
// Two transaction shapes, matched by (group_input_count, group_output_count)
// -- same mint/transfer pattern as claims-registry and the course's own
// typeid contract:
//   MINT (0, 1):     the offer cell is appearing for the first time. Its
//                     own output-side witness (WitnessArgs.lock, 65 bytes)
//                     must be a signature, from `witness_address`, over
//                     `domain_tag(0x01) || recipient_hash` -- the exact
//                     same SECP256K1ETH scheme and domain-separated message
//                     shape mpesa-escrow's own claim-signature check uses,
//                     reused rather than rebuilt (see mpesa-escrow's own
//                     doc comment for why the message length differs from
//                     the 72-byte claim message: so a claim signature can
//                     never be replayed as an ownership proof or vice
//                     versa).
//   TRANSFER (1, 1):  always allowed, no re-check. Since Type Script groups
//                     are keyed by the exact script hash (code_hash +
//                     args), any output continuing this exact hash
//                     necessarily carries the same args -- there is no way
//                     to "transfer" into a cell with a different
//                     recipient_hash/witness_address under this same
//                     identity, so the mint-time proof still holds by
//                     construction.
//   BURN (1, 0):      always allowed. Once mpesa-escrow's own CLAIM path
//                     has checked this badge is present on the escrow cell
//                     being spent, its job is done -- the payout cell going
//                     to the buyer has no reason to carry an "offer
//                     ownership" badge forward, so claims are free to drop
//                     it.
//   Anything else: rejected.
//
// mpesa-escrow's own Lock Script cross-checks, on its CLAIM path, that the
// escrow cell it's releasing carries a Type Script whose hash matches an
// `offer_guard_type_hash` baked into its own args -- see mpesa-escrow's
// doc comment. That's what actually makes this check load-bearing: a
// buyer's claim can only succeed against an escrow cell whose lineage
// traces back to a mint this contract approved.

use alloc::vec::Vec;

use ckb_std::ckb_constants::Source;
use ckb_std::ckb_types::prelude::*;
use ckb_std::high_level::{QueryIter, load_cell_capacity, load_script, load_witness_args};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use sha3::{Digest, Keccak256};

const ARGS_LEN: usize = 52;
const OWNERSHIP_WITNESS_LEN: usize = 65;
const OWNERSHIP_MSG_LEN: usize = 33; // domain_tag(1) + recipient_hash(32)
const OWNERSHIP_DOMAIN_TAG: u8 = 0x01;

const ERROR_ARGS_LEN: i8 = 4;
const ERROR_UNSUPPORTED_STRUCTURE: i8 = 5;
const ERROR_OWNERSHIP_WITNESS_MISSING: i8 = 6;
const ERROR_OWNERSHIP_WITNESS_LEN: i8 = 7;
const ERROR_SIGNATURE_MALFORMED: i8 = 8;
const ERROR_RECOVERY_FAILED: i8 = 9;
const ERROR_OWNERSHIP_ADDRESS_MISMATCH: i8 = 10;

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
    let recipient_hash = &args[20..52];

    let group_input_count = QueryIter::new(load_cell_capacity, Source::GroupInput).count();
    let group_output_count = QueryIter::new(load_cell_capacity, Source::GroupOutput).count();

    match (group_input_count, group_output_count) {
        (0, 1) => {
            // MINT: require a fresh ownership proof, read from this cell's
            // own output-side witness slot -- Type Script groups DO get
            // output_indices populated (unlike Lock Script groups), so
            // Source::GroupOutput is the real, correct index here.
            let witness_args = match load_witness_args(0, Source::GroupOutput) {
                Ok(witness_args) => witness_args,
                Err(_) => return ERROR_OWNERSHIP_WITNESS_MISSING,
            };
            let lock_field = match witness_args.lock().to_opt() {
                Some(field) => field,
                None => return ERROR_OWNERSHIP_WITNESS_MISSING,
            };
            let witness: Vec<u8> = lock_field.unpack();
            if witness.len() != OWNERSHIP_WITNESS_LEN {
                return ERROR_OWNERSHIP_WITNESS_LEN;
            }

            let mut message = [0u8; OWNERSHIP_MSG_LEN];
            message[0] = OWNERSHIP_DOMAIN_TAG;
            message[1..33].copy_from_slice(recipient_hash);

            let recovered_address = match recover_eth_address(&message, &witness) {
                Ok(address) => address,
                Err(code) => return code,
            };
            if recovered_address != expected_witness_address {
                return ERROR_OWNERSHIP_ADDRESS_MISMATCH;
            }
            0
        }
        (1, 1) => 0, // TRANSFER: same script hash both sides, nothing to re-check.
        (1, 0) => 0, // BURN: always allowed, see module doc comment.
        _ => ERROR_UNSUPPORTED_STRUCTURE,
    }
}

/// Recovers the Ethereum-style address that produced `signature`
/// (r || s || v, 65 bytes) over Keccak256(message) -- identical to
/// mpesa-escrow's own `recover_eth_address`, duplicated here rather than
/// shared across the two crates to keep each contract a fully
/// self-contained, independently auditable binary.
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

    let encoded = recovered_key.to_encoded_point(false);
    let pubkey_bytes = &encoded.as_bytes()[1..];

    let mut addr_hasher = Keccak256::new();
    addr_hasher.update(pubkey_bytes);
    let addr_digest = addr_hasher.finalize();

    let mut address = [0u8; 20];
    address.copy_from_slice(&addr_digest[12..32]);
    Ok(address)
}
