//! Step 4: create the escrow offer for real -- and the escrow cell itself
//! must carry the OfferGuard Type Script directly, minted in this SAME
//! transaction, exactly like `tests/src/tests.rs`'s own
//! `build_escrow_claim_tx_with_reservation` attaches it to the escrow
//! input it builds. An earlier version of this tool minted OfferGuard as
//! its own free-standing cell instead (see `mint_offer_guard.rs`) and
//! wired the resulting type hash into the escrow's args -- that satisfies
//! mpesa-escrow's ARGS check but not its actual CLAIM-time cross-check
//! (`load_cell_type_hash(0, GroupInput) == expected`), which reads the
//! escrow cell's own, real attached type script, not just whatever hash
//! happens to be named in args. Confirmed the hard way: a real CLAIM
//! attempt against that free-standing setup failed with error 17
//! (ERROR_OFFER_GUARD_MISSING) on the real chain.
//!
//! Output order here is [change, escrow-with-guard] -- not [escrow,
//! change] -- for the same reason `mint_offer_guard.rs` puts its own
//! change cell first: the escrow's own output index must not collide
//! with the funding input's own sighash witness slot (both would want
//! witnesses[0]), since OfferGuard's own ownership proof is read
//! positionally from the escrow's own *output* index.

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

const AMOUNT: i64 = 25_000; // KES minor units, matching the claim step's own constant

fn ownership_message(recipient_hash: &[u8; 32]) -> [u8; 33] {
    let mut message = [0u8; 33];
    message[0] = 0x01;
    message[1..33].copy_from_slice(recipient_hash);
    message
}

fn main() {
    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let deployed: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed.json")).expect("read deployed.json"),
    )
    .unwrap();
    let registry: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("registry.json")).expect("read registry.json"),
    )
    .unwrap();

    let deploy_tx_hash = deployed["tx_hash"].as_str().unwrap().to_string();
    let escrow_index = deployed["mpesa_escrow_index"].as_u64().unwrap() as u32;
    let guard_index = deployed["offer_guard_index"].as_u64().unwrap() as u32;

    let escrow_binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/mpesa-escrow"))
        .expect("read mpesa-escrow binary");
    let escrow_code_hash = blake2b_256(&escrow_binary);
    let guard_binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/offer-guard"))
        .expect("read offer-guard binary");
    let guard_code_hash = blake2b_256(&guard_binary);

    // Re-use the SAME trusted Verifier this devnet already has (from the
    // earlier, free-standing OfferGuard mint) -- a Verifier's identity
    // doesn't depend on which specific cell later carries the badge.
    let verifier = {
        let text = fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("verifier_key.txt"))
            .expect("read verifier_key.txt (run mint_offer_guard once first so it generates one)");
        let hex_key = text.trim().strip_prefix("0x").unwrap_or(text.trim()).to_string();
        let bytes = hex::decode(hex_key).unwrap();
        EthSigner { key: k256::ecdsa::SigningKey::from_bytes(bytes.as_slice().into()).unwrap() }
    };
    let recipient_hash = [7u8; 32]; // matches the earlier free-standing mint's own choice

    let mut guard_args = Vec::with_capacity(52);
    guard_args.extend_from_slice(&verifier.address());
    guard_args.extend_from_slice(&recipient_hash);
    let guard_type_script = Script::new_builder()
        .code_hash(guard_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(guard_args).pack())
        .build();
    let guard_type_hash: [u8; 32] = guard_type_script.calc_script_hash().unpack();

    let registry_type_hash: [u8; 32] = {
        let cs = &registry["registry_type_script"];
        let script = Script::new_builder()
            .code_hash(hex32(cs["code_hash"].as_str().unwrap()).pack())
            .hash_type(ScriptHashType::Data1)
            .args(Bytes::from(hex::decode(cs["args"].as_str().unwrap().trim_start_matches("0x")).unwrap()).pack())
            .build();
        script.calc_script_hash().unpack()
    };

    let mut escrow_args = Vec::with_capacity(124);
    escrow_args.extend_from_slice(&verifier.address());
    escrow_args.extend_from_slice(&recipient_hash);
    escrow_args.extend_from_slice(&AMOUNT.to_le_bytes());
    escrow_args.extend_from_slice(&registry_type_hash);
    escrow_args.extend_from_slice(&guard_type_hash);
    assert_eq!(escrow_args.len(), 124);

    let escrow_lock_script = Script::new_builder()
        .code_hash(escrow_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(escrow_args).pack())
        .build();

    let (funding_out_point, funding_capacity) = get_one_cell(&lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    let escrow_cell =
        CellOutput::new_builder().lock(escrow_lock_script.clone()).type_(Some(guard_type_script).pack()).build();
    let escrow_capacity = escrow_cell.occupied_capacity(Capacity::zero()).unwrap().as_u64() + 1_000 * 100_000_000; // headroom
    let fee = 100_000_000u64;
    let change_capacity = funding_capacity - escrow_capacity - fee;

    let escrow_output = escrow_cell.as_builder().capacity(escrow_capacity).build();
    let change_output = CellOutput::new_builder().capacity(change_capacity).lock(lock).build();

    // Output order [change, escrow]: the escrow's own output index is 1,
    // not 0, so OfferGuard's ownership-proof witness (read positionally
    // from that output index) lands in witnesses[1], not colliding with
    // the funding input's own sighash witness at witnesses[0].
    let signature = verifier.sign(&ownership_message(&recipient_hash));
    let ownership_witness = WitnessArgs::new_builder()
        .lock(Some(Bytes::from(signature.to_vec())).pack())
        .build()
        .as_bytes();
    let witnesses = vec![WitnessArgs::default().as_bytes(), ownership_witness];

    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(change_output)
        .output(escrow_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witnesses(witnesses.iter().cloned().map(|w| w.pack()))
        .cell_dep(sighash_cell_dep())
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, escrow_index))
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, guard_index))
        .build();

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent create_offer tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");

    let result = json!({
        "tx_hash": tx_hash,
        "escrow_output_index": 1,
        "amount": AMOUNT,
        "recipient_hash": format!("0x{}", hex::encode(recipient_hash)),
        "verifier_address": format!("0x{}", hex::encode(verifier.address())),
        "escrow_lock_script": {
            "code_hash": format!("0x{}", hex::encode(escrow_code_hash)),
            "hash_type": "data1",
            "args": format!("0x{}", hex::encode(escrow_lock_script.args().raw_data())),
        },
        "guard_type_script": {
            "code_hash": format!("0x{}", hex::encode(guard_code_hash)),
            "hash_type": "data1",
            "args": format!("0x{}{}", hex::encode(verifier.address()), hex::encode(recipient_hash)),
        },
        "guard_type_hash": format!("0x{}", hex::encode(guard_type_hash)),
    });
    let out_path = devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("offer.json");
    fs::write(&out_path, serde_json::to_string_pretty(&result).unwrap()).unwrap();
    println!("Wrote {}", out_path.display());
}
