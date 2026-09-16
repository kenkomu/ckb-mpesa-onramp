//! Mints a fresh claims-registry cell locked by the new always-success
//! lock instead of the deploying key -- see the always-success contract's
//! own doc comment for why. Overwrites `registry.json`: this becomes the
//! canonical registry for every offer created from here on. The original
//! registry cell (from `mint_registry.rs`) is left alone on-chain; it's
//! just no longer referenced by anything new.

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

    let always_success: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed_always_success.json"))
            .expect("read deployed_always_success.json (run deploy_always_success first)"),
    )
    .unwrap();
    let always_success_tx_hash = always_success["tx_hash"].as_str().unwrap().to_string();
    let always_success_index = always_success["index"].as_u64().unwrap() as u32;

    let always_success_binary =
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/always-success")).unwrap();
    let always_success_code_hash = blake2b_256(&always_success_binary);
    let always_success_lock = Script::new_builder()
        .code_hash(always_success_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::new().pack())
        .build();

    let deployed: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed.json")).unwrap(),
    )
    .unwrap();
    let deploy_tx_hash = deployed["tx_hash"].as_str().unwrap().to_string();
    let registry_index = deployed["claims_registry_index"].as_u64().unwrap() as u32;
    let registry_binary =
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/claims-registry")).unwrap();
    let registry_code_hash = blake2b_256(&registry_binary);

    let (funding_out_point, funding_capacity) = get_one_cell(&lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    // Type ID args: blake2b(first_input.as_slice() || output_index_le).
    let type_id_args = blake2b_256(&[funding_input.as_slice(), &0u64.to_le_bytes()].concat());
    let registry_type_script = Script::new_builder()
        .code_hash(registry_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(type_id_args.to_vec()).pack())
        .build();

    let base_output =
        CellOutput::new_builder().lock(always_success_lock).type_(Some(registry_type_script.clone()).pack()).build();
    let min_capacity = base_output.occupied_capacity(Capacity::zero()).unwrap().as_u64();
    let registry_capacity = min_capacity + 1_000 * 100_000_000; // headroom for future claims
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
        .cell_dep(deployed_binary_cell_dep(&always_success_tx_hash, always_success_index))
        .build();

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent remint_registry tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed. This is now the canonical, permissionless registry.");

    let result = json!({
        "tx_hash": tx_hash,
        "registry_type_hash": format!("0x{}", hex::encode({
            let hash: [u8; 32] = registry_type_script.calc_script_hash().unpack();
            hash
        })),
        "registry_type_script": {
            "code_hash": format!("0x{}", hex::encode(registry_code_hash)),
            "hash_type": "data1",
            "args": format!("0x{}", hex::encode(type_id_args)),
        },
        "always_success_code_hash": format!("0x{}", hex::encode(always_success_code_hash)),
    });
    let out_path = devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("registry.json");
    fs::write(&out_path, serde_json::to_string_pretty(&result).unwrap()).unwrap();
    println!("Wrote {} (overwritten -- this is now the canonical registry)", out_path.display());
}
