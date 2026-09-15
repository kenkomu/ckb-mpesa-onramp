//! Deploys the new always-success lock binary as its own data cell,
//! separately from the original `deploy.rs` run (which predates this
//! contract). Writes `deployed_always_success.json` with its OutPoint.
//! Even a 21KB binary needs ~21,232 CKB of capacity -- more than a
//! single ~2010 CKB cellbase cell provides -- so this aggregates cells
//! the same way `deploy.rs` does, rather than using `get_one_cell`.

use ckb_types::{
    bytes::Bytes,
    core::{Capacity, TransactionBuilder},
    packed::{CellInput, CellOutput, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use serde_json::json;
use std::fs;
use std::path::Path;

fn main() {
    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/always-success"))
        .expect("read always-success binary");

    let output = CellOutput::new_builder().lock(lock.clone()).build();
    let capacity = output.occupied_capacity(Capacity::bytes(binary.len()).unwrap()).unwrap().as_u64();
    let change_min = CellOutput::new_builder().lock(lock.clone()).build().occupied_capacity(Capacity::zero()).unwrap().as_u64();
    let fee = 100_000_000u64;
    let need = capacity + change_min + fee;

    let (inputs, collected_total) = collect_cells(&lock, need);
    println!("Collected {} input cells totaling {} CKB", inputs.len(), collected_total as f64 / 1e8);

    let change_capacity = collected_total - capacity - fee;
    let always_success_output = output.as_builder().capacity(capacity).build();
    let change_output = CellOutput::new_builder().capacity(change_capacity).lock(lock).build();

    let cell_inputs: Vec<CellInput> =
        inputs.iter().map(|(op, _)| CellInput::new_builder().previous_output(op.clone()).build()).collect();
    let group_input_count = cell_inputs.len();

    let empty_witness = WitnessArgs::default().as_bytes();
    let witnesses: Vec<Bytes> = std::iter::once(empty_witness.clone())
        .chain(std::iter::repeat(empty_witness).take(group_input_count.saturating_sub(1)))
        .collect();

    let tx = TransactionBuilder::default()
        .inputs(cell_inputs)
        .output(always_success_output)
        .output(change_output)
        .outputs_data(vec![Bytes::from(binary), Bytes::new()].pack())
        .witnesses(witnesses.iter().cloned().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &signing_key, 0, group_input_count, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent deploy_always_success tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");

    let out_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("deployed_always_success.json");
    fs::write(&out_path, json!({"tx_hash": tx_hash, "index": 0}).to_string()).unwrap();
    println!("Wrote {}", out_path.display());
}
