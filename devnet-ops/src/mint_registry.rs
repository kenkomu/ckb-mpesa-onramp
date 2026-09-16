//! Step 2: mint the claims-registry cell for real, on-chain -- the exact
//! same Type ID mint pattern `tests/src/tests.rs`'s `mint_registry` helper
//! exercises against ckb-testtool's mocked VM, just with a genuine funding
//! input, a genuine signature, and a genuine miner actually including it
//! in a block.

use ckb_types::{
    bytes::Bytes,
    core::{Capacity, ScriptHashType, TransactionBuilder},
    packed::{CellInput, CellOutput, Script, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use serde_json::json;
use std::fs;
use std::path::Path;

fn main() {
    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let deployed: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed.json"))
            .expect("read deployed.json (run `cargo run --bin deploy` first)"),
    )
    .unwrap();
    let deploy_tx_hash = deployed["tx_hash"].as_str().unwrap().to_string();
    let registry_index = deployed["claims_registry_index"].as_u64().unwrap() as u32;

    let registry_binary = fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/claims-registry"),
    )
    .expect("read claims-registry binary");
    let registry_code_hash = blake2b_256(&registry_binary);

    let (funding_out_point, funding_capacity) = get_one_cell(&lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    // Type ID args: blake2b(first_input.as_slice() || output_index_le) --
    // exactly what ckb_std::type_id::check_type_id expects, and exactly
    // what tests.rs's `type_id_args_for_first_input` computes.
    let type_id_args = blake2b_256(&[funding_input.as_slice(), &0u64.to_le_bytes()].concat());
    let registry_type_script = Script::new_builder()
        .code_hash(registry_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(type_id_args.to_vec()).pack())
        .build();

    // Generous headroom over the empty-data minimum, so this cell can
    // absorb a handful of appended 32-byte claim hashes later without
    // needing a capacity-topping-up transaction of its own.
    let base_output = CellOutput::new_builder().lock(lock.clone()).type_(Some(registry_type_script.clone()).pack()).build();
    let min_capacity = base_output.occupied_capacity(Capacity::zero()).unwrap().as_u64();
    let registry_capacity = min_capacity + 1_000 * 100_000_000; // +1000 CKB slack
    let fee = 100_000_000u64;
    let change_capacity = funding_capacity - registry_capacity - fee;

    let registry_output = base_output.as_builder().capacity(registry_capacity).build();
    let change_output = CellOutput::new_builder().capacity(change_capacity).lock(lock).build();

    let witnesses = vec![WitnessArgs::default().as_bytes()];

    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(registry_output)
        .output(change_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witness(witnesses[0].clone().pack())
        .cell_dep(sighash_cell_dep())
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, registry_index))
        .build();

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent mint_registry tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");

    let result = json!({
        "tx_hash": tx_hash,
        "registry_type_hash": format!("0x{}", hex::encode(registry_type_script.calc_script_hash().as_slice())),
        "registry_type_script": {
            "code_hash": format!("0x{}", hex::encode(registry_code_hash)),
            "hash_type": "data1",
            "args": format!("0x{}", hex::encode(type_id_args)),
        },
    });
    let out_path = devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("registry.json");
    fs::write(&out_path, serde_json::to_string_pretty(&result).unwrap()).unwrap();
    println!("Wrote {}", out_path.display());
}
