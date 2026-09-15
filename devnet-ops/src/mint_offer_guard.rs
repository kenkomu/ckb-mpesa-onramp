//! Step 3: mint the offer-guard cell for real, with a genuine ownership
//! signature from a freshly-generated "trusted Verifier" key -- the same
//! SECP256K1ETH scheme, domain-separated ownership message, and mint/
//! transfer/burn Type Script shape `tests/src/tests.rs`'s
//! `mint_offer_guard` helper already exercises against ckb-testtool.
//!
//! Puts a change output BEFORE the offer-guard cell (output index 0, not
//! 1) so the funding input's own sighash witness (witnesses[0]) and the
//! offer-guard's own ownership-proof witness (read positionally from
//! witnesses[1], via its output index) don't collide in the same slot --
//! a real wiring detail no mocked test needed to handle.

use ckb_types::{
    bytes::Bytes,
    core::{Capacity, ScriptHashType, TransactionBuilder},
    packed::{CellInput, CellOutput, Script, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use k256::ecdsa::SigningKey;
use serde_json::json;
use std::fs;
use std::path::Path;

const RECIPIENT_HASH: [u8; 32] = [7u8; 32]; // hash(seller's M-Pesa number), stand-in for this devnet run

fn ownership_message(recipient_hash: &[u8; 32]) -> [u8; 33] {
    let mut message = [0u8; 33];
    message[0] = 0x01;
    message[1..33].copy_from_slice(recipient_hash);
    message
}

fn load_or_create_verifier(manifest_dir: &str) -> EthSigner {
    let path = Path::new(manifest_dir).join("verifier_key.txt");
    if let Ok(text) = fs::read_to_string(&path) {
        let hex_key = text.trim().strip_prefix("0x").unwrap_or(text.trim()).to_string();
        let bytes = hex::decode(hex_key).expect("valid hex in verifier_key.txt");
        let key = SigningKey::from_bytes(bytes.as_slice().into()).expect("valid secp256k1 key");
        EthSigner { key }
    } else {
        let signer = EthSigner::random();
        fs::write(&path, format!("0x{}", hex::encode(signer.key.to_bytes()))).unwrap();
        signer
    }
}

fn main() {
    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let verifier = load_or_create_verifier(env!("CARGO_MANIFEST_DIR"));
    println!("Verifier (trusted) Ethereum-style address: 0x{}", hex::encode(verifier.address()));

    let deployed: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("deployed.json")).expect("read deployed.json"),
    )
    .unwrap();
    let deploy_tx_hash = deployed["tx_hash"].as_str().unwrap().to_string();
    let guard_index = deployed["offer_guard_index"].as_u64().unwrap() as u32;

    let guard_binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/offer-guard"))
        .expect("read offer-guard binary");
    let guard_code_hash = blake2b_256(&guard_binary);

    let (funding_out_point, funding_capacity) = get_one_cell(&lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    let mut guard_args = Vec::with_capacity(52);
    guard_args.extend_from_slice(&verifier.address());
    guard_args.extend_from_slice(&RECIPIENT_HASH);
    let guard_type_script = Script::new_builder()
        .code_hash(guard_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(guard_args).pack())
        .build();

    let guard_cell = CellOutput::new_builder().lock(lock.clone()).type_(Some(guard_type_script.clone()).pack()).build();
    let guard_capacity = guard_cell.occupied_capacity(Capacity::zero()).unwrap().as_u64();
    let fee = 100_000_000u64;
    let change_capacity = funding_capacity - guard_capacity - fee;

    let change_output = CellOutput::new_builder().capacity(change_capacity).lock(lock).build();
    let guard_output = guard_cell.as_builder().capacity(guard_capacity).build();

    // Output order: [change, guard] -- guard's own output index is 1, not
    // 0, so its ownership witness lives at witnesses[1], not colliding
    // with the funding input's own sighash witness at witnesses[0].
    let signature = verifier.sign(&ownership_message(&RECIPIENT_HASH));
    let ownership_witness = WitnessArgs::new_builder()
        .lock(Some(Bytes::from(signature.to_vec())).pack())
        .build()
        .as_bytes();
    let witnesses = vec![WitnessArgs::default().as_bytes(), ownership_witness];

    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(change_output)
        .output(guard_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witnesses(witnesses.iter().cloned().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, guard_index))
        .build();

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent mint_offer_guard tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");

    let guard_type_hash = guard_type_script.calc_script_hash();
    let result = json!({
        "tx_hash": tx_hash,
        "guard_output_index": 1,
        "recipient_hash": format!("0x{}", hex::encode(RECIPIENT_HASH)),
        "verifier_address": format!("0x{}", hex::encode(verifier.address())),
        "guard_type_script": {
            "code_hash": format!("0x{}", hex::encode(guard_code_hash)),
            "hash_type": "data1",
            "args": format!("0x{}{}", hex::encode(verifier.address()), hex::encode(RECIPIENT_HASH)),
        },
        "guard_type_hash": format!("0x{}", hex::encode(guard_type_hash.as_slice())),
    });
    let out_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("offer_guard.json");
    fs::write(&out_path, serde_json::to_string_pretty(&result).unwrap()).unwrap();
    println!("Wrote {}", out_path.display());
}
