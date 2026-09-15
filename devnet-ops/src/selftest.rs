//! Minimal single-input self-transfer, to validate `sign_group` against
//! the real secp256k1_blake160_sighash_all system script before trusting
//! it on a real 147-input deploy transaction.

use ckb_types::{
    bytes::Bytes,
    core::TransactionBuilder,
    packed::{CellInput, CellOutput, OutPoint, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use k256::ecdsa::{RecoveryId, Signature, SigningKey, VerifyingKey};
use k256::elliptic_curve::sec1::ToEncodedPoint;
use serde_json::json;
use std::fs;
use std::path::Path;

/// Offline sanity check, independent of the chain: recover the pubkey from
/// a signature exactly the way ckb-system-scripts' C implementation does,
/// and confirm blake160(recovered pubkey) matches our own lock args --
/// catches a signing bug before spending an RPC round-trip on it.
fn self_check_signature(digest: &[u8; 32], sig_bytes: &[u8; 65], expected_blake160: &[u8; 20]) {
    let sig = Signature::from_slice(&sig_bytes[..64]).expect("parse signature");
    let recid = RecoveryId::from_byte(sig_bytes[64]).expect("valid recovery id");
    let recovered = VerifyingKey::recover_from_prehash(digest, &sig, recid).expect("recover pubkey");
    let compressed = recovered.to_encoded_point(true);
    let blake160 = blake160_of_pubkey(compressed.as_bytes());
    println!(
        "offline self-check: recovered blake160=0x{} expected=0x{} match={}",
        hex::encode(blake160),
        hex::encode(expected_blake160),
        &blake160 == expected_blake160
    );
    assert_eq!(&blake160, expected_blake160, "offline signature self-check failed");
}

fn main() {
    let text = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("devnet_key.txt")).unwrap();
    let mut private_key_hex = None;
    let mut blake160_hex = None;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("private_key=0x") {
            private_key_hex = Some(v.trim().to_string());
        }
        if let Some(v) = line.strip_prefix("lock_args_blake160=0x") {
            blake160_hex = Some(v.trim().to_string());
        }
    }
    let sk_bytes = hex::decode(private_key_hex.unwrap()).unwrap();
    let signing_key = SigningKey::from_bytes(sk_bytes.as_slice().into()).unwrap();
    let blake160_vec = hex::decode(blake160_hex.unwrap()).unwrap();
    let mut blake160 = [0u8; 20];
    blake160.copy_from_slice(&blake160_vec);
    let lock = sighash_lock(&blake160);

    let script_json = json!({
        "code_hash": format!("0x{}", hex::encode(lock.code_hash().raw_data())),
        "hash_type": "type",
        "args": format!("0x{}", hex::encode(lock.args().raw_data())),
    });
    let result = rpc_call("get_cells", json!([{"script": script_json, "script_type": "lock"}, "asc", "0x1"]));
    let obj = result["objects"][0].clone();
    let tx_hash_hex = obj["out_point"]["tx_hash"].as_str().unwrap().to_string();
    let index = u32::from_str_radix(obj["out_point"]["index"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    let capacity = u64::from_str_radix(obj["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    println!("Using input {tx_hash_hex}:{index} capacity={} CKB", capacity as f64 / 1e8);

    let tx_hash_vec = hex::decode(tx_hash_hex.trim_start_matches("0x")).unwrap();
    let mut tx_hash_arr = [0u8; 32];
    tx_hash_arr.copy_from_slice(&tx_hash_vec);
    let out_point = OutPoint::new_builder().tx_hash(tx_hash_arr.pack()).index(index).build();
    let input = CellInput::new_builder().previous_output(out_point).build();

    let fee = 100_000_000u64;
    let output = CellOutput::new_builder().capacity(capacity - fee).lock(lock).build();

    let empty_witness = WitnessArgs::default().as_bytes();
    let witnesses = vec![empty_witness];

    let tx = TransactionBuilder::default()
        .input(input)
        .output(output)
        .output_data(Bytes::new().pack())
        .witness(witnesses[0].clone().pack())
        .cell_dep(sighash_cell_dep())
        .build();

    // Replicate sign_group's own digest computation here, independently,
    // so the offline self-check below can verify it before trusting the
    // shared helper.
    let tx_hash = tx.hash();
    let zeroed_witness0 = WitnessArgs::new_builder()
        .lock(Some(Bytes::from(vec![0u8; 65])).pack())
        .build()
        .as_bytes();
    let mut blake2b = ckb_hash::new_blake2b();
    blake2b.update(tx_hash.as_slice());
    blake2b.update(&(zeroed_witness0.len() as u64).to_le_bytes());
    blake2b.update(&zeroed_witness0);
    let mut digest = [0u8; 32];
    blake2b.finalize(&mut digest);

    let (sig, recid): (Signature, RecoveryId) =
        signing_key.sign_prehash_recoverable(&digest).expect("sign_prehash_recoverable");
    let mut sig_bytes = [0u8; 65];
    sig_bytes[..64].copy_from_slice(&sig.to_bytes());
    sig_bytes[64] = recid.to_byte();
    self_check_signature(&digest, &sig_bytes, &blake160);

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent selftest tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed! Self-transfer signature verified against the real system script.");
}
