//! One-off: send CKB to a given sighash lock's blake160 args directly,
//! without needing the target's private key -- for funding a browser
//! wallet from its own displayed address (decoded via `ckb-cli util
//! address-info`) rather than pasting a private key around. Not part of
//! the shipped app, just a devnet testing convenience.
//! Usage: cargo run --bin fund_lock_args -- <0x-prefixed 20-byte blake160> [amount_ckb]

use ckb_types::{bytes::Bytes, core::TransactionBuilder, packed::{CellInput, CellOutput, WitnessArgs}, prelude::*};
use devnet_ops::*;

fn main() {
    let mut args = std::env::args().skip(1);
    let target_blake160_hex = args.next().expect("usage: fund_lock_args <0x-prefixed 20-byte blake160> [amount_ckb]");
    let amount_ckb: u64 = args.next().map(|s| s.parse().expect("amount_ckb must be an integer")).unwrap_or(2000);

    let target_blake160_vec = hex::decode(target_blake160_hex.trim_start_matches("0x")).expect("valid hex");
    let target_blake160: [u8; 20] = target_blake160_vec.try_into().expect("blake160 must be exactly 20 bytes");
    let target_lock = sighash_lock(&target_blake160);

    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let send_amount = amount_ckb * 100_000_000;
    let fee = 100_000_000u64;
    // A single ~2009 CKB cellbase cell isn't always enough (send_amount +
    // fee + a minimum-capacity change cell) -- collect_cells aggregates
    // as many as needed instead, same as deploy.rs/deploy_always_success.rs.
    let (cells, funding_capacity) = collect_cells(&lock, send_amount + fee + 6_100_000_000);
    let funding_inputs: Vec<CellInput> =
        cells.iter().map(|(op, _)| CellInput::new_builder().previous_output(op.clone()).build()).collect();

    let target_output = CellOutput::new_builder().capacity(send_amount).lock(target_lock).build();
    let change_output =
        CellOutput::new_builder().capacity(funding_capacity - send_amount - fee).lock(lock).build();

    let witnesses: Vec<Bytes> = std::iter::once(WitnessArgs::default().as_bytes())
        .chain(std::iter::repeat(Bytes::new()).take(funding_inputs.len() - 1))
        .collect();
    let mut builder = TransactionBuilder::default();
    for input in funding_inputs.iter() {
        builder = builder.input(input.clone());
    }
    let tx = builder
        .output(target_output)
        .output(change_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witnesses(witnesses.iter().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &signing_key, 0, funding_inputs.len(), witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent fund_lock_args tx: {tx_hash} ({amount_ckb} CKB)");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");
}
