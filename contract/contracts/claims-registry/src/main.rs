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

// ClaimsRegistry -- the nullifier for Bitshada's M-Pesa claims.
//
// CKB has no "has this ever existed" syscall the way an account-chain's
// contract storage does, so Type ID alone (which only guarantees a *given*
// mint event derives a fresh, collision-free identity from an input
// outpoint) can't by itself stop the same external fact -- an M-Pesa
// transaction ID -- from being claimed twice across two *different*
// transactions. The mechanism here instead: exactly one, continuously-live
// registry cell (minted once via Type ID, exactly like
// scripting-basics-labs/contracts/typeid) whose data is an append-only list
// of 32-byte tx_id hashes already claimed. Every claim transaction must
// consume the current registry cell and recreate it with exactly one new
// hash appended -- and this script rejects that update if the hash being
// appended already appears anywhere in the existing list. Consuming a cell
// is a one-time act on CKB, so this genuinely serializes every claim through
// one cell, the same way AggDoubleCounter/ODDoubleCounter (Weeks 8-9)
// serialize updates to a single shared counter.
//
// This is real, working replay protection, not a stand-in -- but it's a
// flat, linearly-scanned list, which is an honest MVP simplification: a
// Merkle-tree-backed accumulator would be the right design past a small
// number of real claims, and is explicitly out of scope for this grant.

use ckb_std::ckb_constants::Source;
use ckb_std::high_level::{QueryIter, load_cell_capacity, load_cell_data};
use ckb_std::type_id::check_type_id;

const HASH_LEN: usize = 32;

const ERROR_TYPE_ID: i8 = 4;
const ERROR_MINT_NOT_EMPTY: i8 = 5;
const ERROR_UPDATE_LENGTH: i8 = 6;
const ERROR_UPDATE_PREFIX_CHANGED: i8 = 7;
const ERROR_DUPLICATE_CLAIM: i8 = 8;
const ERROR_UNSUPPORTED_STRUCTURE: i8 = 9;

pub fn program_entry() -> i8 {
    let group_input_count = QueryIter::new(load_cell_capacity, Source::GroupInput).count();
    let group_output_count = QueryIter::new(load_cell_capacity, Source::GroupOutput).count();
    ckb_std::debug!(
        "claims-registry: group_input_count = {}, group_output_count = {}",
        group_input_count,
        group_output_count
    );

    if check_type_id(0, 32).is_err() {
        return ERROR_TYPE_ID;
    }

    match (group_input_count, group_output_count) {
        (0, 1) => {
            // Mint: the registry starts life empty.
            let data = load_cell_data(0, Source::GroupOutput).unwrap_or_default();
            if data.is_empty() {
                0
            } else {
                ERROR_MINT_NOT_EMPTY
            }
        }
        (1, 1) => {
            let old_data = load_cell_data(0, Source::GroupInput).unwrap_or_default();
            let new_data = load_cell_data(0, Source::GroupOutput).unwrap_or_default();

            if new_data.len() != old_data.len() + HASH_LEN {
                return ERROR_UPDATE_LENGTH;
            }
            if new_data[..old_data.len()] != old_data[..] {
                return ERROR_UPDATE_PREFIX_CHANGED;
            }

            let new_hash = &new_data[old_data.len()..];
            let already_claimed = old_data.chunks(HASH_LEN).any(|chunk| chunk == new_hash);
            if already_claimed {
                ckb_std::debug!("claims-registry: duplicate claim rejected");
                return ERROR_DUPLICATE_CLAIM;
            }

            0
        }
        // No burn path in this MVP -- the registry is meant to live forever.
        _ => ERROR_UNSUPPORTED_STRUCTURE,
    }
}
