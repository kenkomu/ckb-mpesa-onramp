//! One-off: sweep ALL of a source key's live cells to a target lock's
//! blake160 args, minus a flat fee. Used to consolidate several separate
//! testnet faucet claims (each capped per address) into the one deploy
//! key that actually needs the large balance.
//! Usage: cargo run --bin sweep -- <source_key_file> <target_blake160>
//! Reads CKB_RPC_URL/CKB_SIGHASH_DEP_GROUP_*/CKB_DATA_DIR the same as
//! every other binary in this crate.

use ckb_types::{bytes::Bytes, core::TransactionBuilder, packed::{CellInput, CellOutput, WitnessArgs}, prelude::*};
use devnet_ops::*;
use k256::ecdsa::SigningKey;

fn main() {
    let mut args = std::env::args().skip(1);
    let source_key_file = args.next().expect("usage: sweep <source_key_file> <target_blake160>");
    let target_blake160_hex = args.next().expect("usage: sweep <source_key_file> <target_blake160>");

    let source_text = std::fs::read_to_string(data_dir(env!("CARGO_MANIFEST_DIR")).join(&source_key_file))
        .unwrap_or_else(|_| panic!("read {source_key_file}"));
    let source_key_hex = source_text
        .lines()
        .find_map(|l| l.strip_prefix("private_key=0x"))
        .expect("private_key=0x.. line in source key file");
    let source_key_bytes = hex::decode(source_key_hex.trim()).expect("valid hex");
    let source_key = SigningKey::from_bytes(source_key_bytes.as_slice().into()).expect("valid secp256k1 key");
    let source_compressed = source_key.verifying_key().to_encoded_point(true);
    let source_blake160 = blake160_of_pubkey(source_compressed.as_bytes());
    let source_lock = sighash_lock(&source_blake160);
    println!("Sweeping from blake160: 0x{}", hex::encode(source_blake160));

    let target_blake160_vec = hex::decode(target_blake160_hex.trim_start_matches("0x")).expect("valid hex");
    let target_blake160: [u8; 20] = target_blake160_vec.try_into().expect("target blake160 must be exactly 20 bytes");
    let target_lock = sighash_lock(&target_blake160);

    let total_balance = get_cells_capacity(&source_lock);
    let fee = 100_000_000u64; // 1 CKB flat fee
    if total_balance <= fee {
        panic!("nothing meaningful to sweep: only {total_balance} shannon at the source lock");
    }

    let (cells, collected_total) = collect_cells(&source_lock, total_balance);
    let inputs: Vec<CellInput> =
        cells.iter().map(|(op, _)| CellInput::new_builder().previous_output(op.clone()).build()).collect();
    // Re-derive the real spendable amount from what collect_cells
    // actually gathered, rather than trusting the earlier
    // get_cells_capacity snapshot (a block could land in between).
    let send_amount = collected_total - fee;

    let outputs = vec![CellOutput::new_builder().capacity(send_amount).lock(target_lock).build()];
    let outputs_data_final = vec![Bytes::new()];

    let witnesses: Vec<Bytes> = std::iter::once(WitnessArgs::default().as_bytes())
        .chain(std::iter::repeat(Bytes::new()).take(inputs.len().saturating_sub(1)))
        .collect();

    let mut builder = TransactionBuilder::default();
    for input in inputs.iter() {
        builder = builder.input(input.clone());
    }
    let tx = builder
        .outputs(outputs)
        .outputs_data(outputs_data_final.pack())
        .witnesses(witnesses.iter().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &source_key, 0, inputs.len(), witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent sweep tx: {tx_hash} ({} CKB)", send_amount as f64 / 1e8);
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");
}
