//! Step 1: deploy the three contract binaries (claims-registry,
//! mpesa-escrow, offer-guard) as plain data cells on the local devnet,
//! funded by aggregating however many mined cellbase cells it takes.
//! Prints each deployed cell's OutPoint (tx_hash:index) as JSON, to be
//! consumed as `cell_deps` by every later step.

use ckb_types::{
    bytes::Bytes,
    core::{Capacity, TransactionBuilder},
    packed::{CellInput, CellOutput, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

fn main() {
    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let build_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release");
    let binaries = [
        ("claims-registry", fs::read(build_dir.join("claims-registry")).expect("read claims-registry binary")),
        ("mpesa-escrow", fs::read(build_dir.join("mpesa-escrow")).expect("read mpesa-escrow binary")),
        ("offer-guard", fs::read(build_dir.join("offer-guard")).expect("read offer-guard binary")),
    ];

    // Exact minimum occupied capacity per binary's own data cell.
    let mut output_capacities = Vec::new();
    for (name, data) in &binaries {
        let output = CellOutput::new_builder().lock(lock.clone()).build();
        let occupied = output
            .occupied_capacity(Capacity::bytes(data.len()).unwrap())
            .unwrap_or_else(|e| panic!("occupied_capacity for {name}: {e}"));
        output_capacities.push(occupied.as_u64());
    }
    let outputs_total: u64 = output_capacities.iter().sum();
    // A little headroom for the change cell's own minimum capacity (61
    // CKB for a bare secp256k1 cell) plus a flat fee -- generous since
    // devnet cellbase cells are cheap to come by.
    let change_min = CellOutput::new_builder().lock(lock.clone()).build().occupied_capacity(Capacity::zero()).unwrap().as_u64();
    let fee = 100_000_000u64; // 1 CKB flat fee, plenty on a devnet
    let need = outputs_total + change_min + fee;

    println!("Need {} CKB total ({} CKB in deployed binaries + {} CKB change + fee)", need as f64 / 1e8, outputs_total as f64 / 1e8, change_min as f64 / 1e8);

    let (inputs, collected_total) = collect_cells(&lock, need);
    println!("Collected {} input cells totaling {} CKB", inputs.len(), collected_total as f64 / 1e8);

    let change_capacity = collected_total - outputs_total - fee;

    let mut outputs = vec![];
    let mut outputs_data = vec![];
    for ((_, data), capacity) in binaries.iter().zip(output_capacities.iter()) {
        outputs.push(CellOutput::new_builder().capacity(*capacity).lock(lock.clone()).build());
        outputs_data.push(Bytes::from(data.clone()));
    }
    outputs.push(CellOutput::new_builder().capacity(change_capacity).lock(lock.clone()).build());
    outputs_data.push(Bytes::new());

    let cell_inputs: Vec<CellInput> = inputs
        .iter()
        .map(|(op, _)| CellInput::new_builder().previous_output(op.clone()).build())
        .collect();
    let group_input_count = cell_inputs.len();

    let empty_witness = WitnessArgs::default().as_bytes();
    let witnesses: Vec<Bytes> = std::iter::once(empty_witness.clone())
        .chain(std::iter::repeat(empty_witness).take(group_input_count.saturating_sub(1)))
        .collect();

    let tx = TransactionBuilder::default()
        .inputs(cell_inputs)
        .outputs(outputs)
        .outputs_data(outputs_data.pack())
        .witnesses(witnesses.iter().cloned().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &signing_key, 0, group_input_count, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent deploy tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");

    let result: Value = json!({
        "tx_hash": tx_hash,
        "claims_registry_index": 0,
        "mpesa_escrow_index": 1,
        "offer_guard_index": 2,
        "change_index": 3,
    });
    let out_path = devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed.json");
    fs::write(&out_path, serde_json::to_string_pretty(&result).unwrap()).unwrap();
    println!("Wrote {}", out_path.display());
}
