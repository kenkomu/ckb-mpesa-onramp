//! Step 5: the real end-to-end proof -- RESERVE the offer for a distinct
//! "buyer" key, then CLAIM it with a genuine Verifier-signed payment claim
//! and a genuine nullifier-registry update, all in one final transaction.
//! This is the same combined flow `build_escrow_claim_tx_with_reservation`
//! exercises against ckb-testtool's mocked VM in `tests/src/tests.rs`,
//! just against real cells, a real signature, and a real miner.

use ckb_types::{
    bytes::Bytes,
    core::{ScriptHashType, TransactionBuilder},
    packed::{CellInput, CellOutput, OutPoint, Script, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use k256::ecdsa::SigningKey;
use serde_json::json;
use std::fs;
use std::path::Path;

const AMOUNT: i64 = 25_000;

fn claim_message(tx_id_hash: &[u8; 32], recipient_hash: &[u8; 32], amount: i64) -> [u8; 72] {
    let mut message = [0u8; 72];
    message[0..32].copy_from_slice(tx_id_hash);
    message[32..64].copy_from_slice(recipient_hash);
    message[64..72].copy_from_slice(&amount.to_le_bytes());
    message
}

fn load_or_create_buyer(manifest_dir: &str) -> ([u8; 20], SigningKey) {
    let path = devnet_ops::data_dir(manifest_dir).join("buyer_key.txt");
    if let Ok(text) = fs::read_to_string(&path) {
        let hex_key = text.trim().strip_prefix("0x").unwrap_or(text.trim()).to_string();
        let bytes = hex::decode(hex_key).expect("valid hex in buyer_key.txt");
        let key = SigningKey::from_bytes(bytes.as_slice().into()).expect("valid secp256k1 key");
        let compressed = key.verifying_key().to_encoded_point(true);
        (blake160_of_pubkey(compressed.as_bytes()), key)
    } else {
        let key = SigningKey::random(&mut rand::thread_rng());
        fs::write(&path, format!("0x{}", hex::encode(key.to_bytes()))).unwrap();
        let compressed = key.verifying_key().to_encoded_point(true);
        (blake160_of_pubkey(compressed.as_bytes()), key)
    }
}

fn main() {
    // Note: the seller's own key doesn't appear anywhere in this script.
    // It used to have to co-sign the registry input (see
    // registry_lock_script below for why that's gone) -- a real buyer can
    // now submit a claim with nobody else needing to be online to sign.
    let (buyer_blake160, buyer_key) = load_or_create_buyer(env!("CARGO_MANIFEST_DIR"));
    let buyer_lock = sighash_lock(&buyer_blake160);

    let verifier = {
        let text = fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("verifier_key.txt"))
            .expect("read verifier_key.txt (run mint_offer_guard first)");
        let hex_key = text.trim().strip_prefix("0x").unwrap_or(text.trim()).to_string();
        let bytes = hex::decode(hex_key).unwrap();
        EthSigner { key: SigningKey::from_bytes(bytes.as_slice().into()).unwrap() }
    };

    let deployed: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed.json")).unwrap(),
    )
    .unwrap();
    let registry: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("registry.json")).unwrap(),
    )
    .unwrap();
    let always_success: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("deployed_always_success.json")).unwrap(),
    )
    .unwrap();
    let always_success_tx_hash = always_success["tx_hash"].as_str().unwrap().to_string();
    let always_success_index = always_success["index"].as_u64().unwrap() as u32;
    let offer: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("offer.json")).unwrap())
            .unwrap();

    let deploy_tx_hash = deployed["tx_hash"].as_str().unwrap().to_string();
    let escrow_index = deployed["mpesa_escrow_index"].as_u64().unwrap() as u32;
    let registry_index = deployed["claims_registry_index"].as_u64().unwrap() as u32;
    let guard_index = deployed["offer_guard_index"].as_u64().unwrap() as u32;

    let escrow_binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/mpesa-escrow")).unwrap();
    let escrow_code_hash = blake2b_256(&escrow_binary);
    let escrow_args_hex = offer["escrow_lock_script"]["args"].as_str().unwrap().to_string();
    let escrow_lock_script = Script::new_builder()
        .code_hash(escrow_code_hash.pack())
        .hash_type(ScriptHashType::Data1)
        .args(Bytes::from(hex::decode(escrow_args_hex.trim_start_matches("0x")).unwrap()).pack())
        .build();

    let escrow_tx_hash = offer["tx_hash"].as_str().unwrap().to_string();
    let escrow_output_index = offer["escrow_output_index"].as_u64().unwrap() as u32;

    let recipient_hash = hex32(offer["recipient_hash"].as_str().unwrap());
    let guard_type_hash_hex = offer["guard_type_hash"].as_str().unwrap().to_string();
    let guard_type_script = {
        let guard_binary =
            fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/offer-guard")).unwrap();
        let guard_code_hash = blake2b_256(&guard_binary);
        let args_hex = offer["guard_type_script"]["args"].as_str().unwrap().to_string();
        Script::new_builder()
            .code_hash(guard_code_hash.pack())
            .hash_type(ScriptHashType::Data1)
            .args(Bytes::from(hex::decode(args_hex.trim_start_matches("0x")).unwrap()).pack())
            .build()
    };
    assert_eq!(
        hex::encode(guard_type_script.calc_script_hash().as_slice()),
        guard_type_hash_hex.trim_start_matches("0x"),
        "guard_type_script mismatch"
    );

    // === Transaction 1: RESERVE (buyer reserves the open offer) ===
    //
    // Resumable: a previous run may have already gotten the RESERVE
    // transaction committed (it did, the first time this was tried,
    // before discovering the buyer key needed funding for the CLAIM half)
    // -- re-running RESERVE against an already-spent escrow cell would
    // just fail with an unhelpful "cell not found", so skip it if a
    // record of a prior successful RESERVE already exists. Either way,
    // the escrow capacity used for the rest of this script is read back
    // from whichever cell is actually live right now (the original offer
    // cell if RESERVE hasn't run yet, or the reserved cell if it has) --
    // never assumed, since RESERVE's own small fee already shrank it.
    let reserve_state_path = devnet_ops::data_dir(env!("CARGO_MANIFEST_DIR")).join("reserve.json");
    let reserve_tx_hash = if let Ok(text) = fs::read_to_string(&reserve_state_path) {
        let saved: serde_json::Value = serde_json::from_str(&text).unwrap();
        let hash = saved["reserve_tx_hash"].as_str().unwrap().to_string();
        println!("Reusing already-committed RESERVE tx: {hash}");
        hash
    } else {
        let escrow_in_op =
            OutPoint::new_builder().tx_hash(hex32(&escrow_tx_hash).pack()).index(escrow_output_index).build();
        let escrow_input = CellInput::new_builder().previous_output(escrow_in_op).build();
        let escrow_capacity = {
            let result = rpc_call(
                "get_live_cell",
                json!([{"tx_hash": escrow_tx_hash, "index": format!("0x{:x}", escrow_output_index)}, false]),
            );
            u64::from_str_radix(result["cell"]["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16)
                .unwrap()
        };
        // RESERVE needs its own small fee (borrowed from the escrow
        // cell's own 1000 CKB headroom, added at create_offer time) --
        // capacity-in must exceed capacity-out by at least the pool's min
        // fee rate, even for a transaction that otherwise moves no value.
        let reserve_fee = 1_000_000u64; // 0.01 CKB, comfortably over the pool minimum
        let reserved_by_lock_hash: [u8; 32] = buyer_lock.calc_script_hash().unpack();
        // Carries the OfferGuard type script FORWARD (TRANSFER, 1-in/
        // 1-out on OfferGuard's own terms, no re-check needed) -- if
        // RESERVE dropped it instead, the later CLAIM would find no
        // badge at all on the reserved cell and fail check 5's
        // cross-check for a totally different, confusing reason.
        let escrow_reserved_output = CellOutput::new_builder()
            .capacity(escrow_capacity - reserve_fee)
            .lock(escrow_lock_script.clone())
            .type_(Some(guard_type_script.clone()).pack())
            .build();
        let reserve_tx = TransactionBuilder::default()
            .input(escrow_input)
            .output(escrow_reserved_output)
            .outputs_data(vec![Bytes::from(reserved_by_lock_hash.to_vec())].pack())
            .witness(WitnessArgs::default().as_bytes().pack())
            .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, escrow_index))
            .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, guard_index))
            .build();
        // No lock-group signing needed: RESERVE is deliberately
        // unauthorized, mpesa-escrow's own Lock Script never inspects a
        // witness for it.
        let hash = send_transaction(&reserve_tx);
        println!("Sent RESERVE tx: {hash}");
        wait_for_tx(&hash, 60);
        println!("Reserved.");
        fs::write(&reserve_state_path, json!({"reserve_tx_hash": hash}).to_string()).unwrap();
        hash
    };
    let escrow_capacity = {
        let result = rpc_call("get_live_cell", json!([{"tx_hash": reserve_tx_hash, "index": "0x0"}, false]));
        u64::from_str_radix(result["cell"]["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap()
    };

    // === Transaction 2: CLAIM (buyer proves reservation + presents a real Verifier-signed claim) ===
    // A real, freshly-invented "M-Pesa transaction id" for this devnet proof.
    let tx_id_hash = blake2b_256(b"devnet-proof M-Pesa tx id, 2026-09-15, KES 25000");
    let message = claim_message(&tx_id_hash, &recipient_hash, AMOUNT);
    let claim_signature = verifier.sign(&message);
    let claim_witness = {
        let mut w = Vec::with_capacity(137);
        w.extend_from_slice(&tx_id_hash);
        w.extend_from_slice(&recipient_hash);
        w.extend_from_slice(&AMOUNT.to_le_bytes());
        w.extend_from_slice(&claim_signature);
        w
    };

    let reserved_escrow_op = OutPoint::new_builder().tx_hash(hex32(&reserve_tx_hash).pack()).index(0u32).build();
    let reserved_escrow_input = CellInput::new_builder()
        .previous_output(reserved_escrow_op)
        .build();

    let registry_tx_hash = registry["tx_hash"].as_str().unwrap().to_string();
    let registry_out_point = OutPoint::new_builder().tx_hash(hex32(&registry_tx_hash).pack()).index(0u32).build();
    let registry_input = CellInput::new_builder().previous_output(registry_out_point).build();
    let (registry_data, registry_capacity) = {
        let result = rpc_call("get_live_cell", json!([{"tx_hash": registry_tx_hash, "index": "0x0"}, true]));
        let data = hex::decode(result["cell"]["data"]["content"].as_str().unwrap().trim_start_matches("0x")).unwrap();
        let capacity = u64::from_str_radix(result["cell"]["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
        (data, capacity)
    };
    assert!(registry_data.is_empty(), "expected a fresh registry with no claims yet");
    let mut new_registry_data = registry_data;
    new_registry_data.extend_from_slice(&tx_id_hash);
    let registry_lock_script = {
        // The registry cell's own lock is the permissionless always-success
        // lock (see remint_registry.rs / the always-success contract's own
        // doc comment) -- no signature needed at all, by design: the
        // registry's Type Script already fully gates every mutation that
        // matters, so a buyer can submit a claim without needing anyone
        // else to co-sign.
        let always_success_code_hash = hex32(registry["always_success_code_hash"].as_str().unwrap());
        Script::new_builder()
            .code_hash(always_success_code_hash.pack())
            .hash_type(ScriptHashType::Data1)
            .args(Bytes::new().pack())
            .build()
    };
    let registry_type_script = {
        let registry_binary = fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../contract/build/release/claims-registry")).unwrap();
        let registry_code_hash = blake2b_256(&registry_binary);
        let args_hex = registry["registry_type_script"]["args"].as_str().unwrap().to_string();
        Script::new_builder()
            .code_hash(registry_code_hash.pack())
            .hash_type(ScriptHashType::Data1)
            .args(Bytes::from(hex::decode(args_hex.trim_start_matches("0x")).unwrap()).pack())
            .build()
    };

    let registry_output = CellOutput::new_builder()
        .capacity(registry_capacity)
        .lock(registry_lock_script)
        .type_(Some(registry_type_script).pack())
        .build();

    let escrow_payout_output = CellOutput::new_builder().capacity(escrow_capacity).lock(buyer_lock.clone()).build();

    // Buyer's own funding input -- its presence, locked by buyer_lock, is
    // what mpesa-escrow's reservation check verifies against.
    let (buyer_funding_op, buyer_funding_capacity) = get_one_cell(&buyer_lock);
    let buyer_funding_input = CellInput::new_builder().previous_output(buyer_funding_op).build();
    let fee = 100_000_000u64;
    let buyer_change_output =
        CellOutput::new_builder().capacity(buyer_funding_capacity - fee).lock(buyer_lock).build();

    let escrow_witness_args = WitnessArgs::new_builder().lock(Some(Bytes::from(claim_witness)).pack()).build().as_bytes();
    let buyer_witness = WitnessArgs::default().as_bytes();
    let registry_witness = WitnessArgs::default().as_bytes();

    let claim_tx = TransactionBuilder::default()
        .input(reserved_escrow_input)
        .input(buyer_funding_input)
        .input(registry_input)
        .output(escrow_payout_output)
        .output(buyer_change_output)
        .output(registry_output)
        .outputs_data(vec![Bytes::new(), Bytes::new(), Bytes::from(new_registry_data)].pack())
        .witness(escrow_witness_args.pack())
        .witness(buyer_witness.clone().pack())
        .witness(registry_witness.clone().pack())
        .cell_dep(sighash_cell_dep())
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, escrow_index))
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, registry_index))
        .cell_dep(deployed_binary_cell_dep(&deploy_tx_hash, guard_index))
        .cell_dep(deployed_binary_cell_dep(&always_success_tx_hash, always_success_index))
        .build();

    // Two of this transaction's three script groups need no signing at
    // all: input 0 (escrow, a CUSTOM lock) never calls into the sighash
    // algorithm -- its own witness (the claim, embedded above) is
    // everything it reads -- and input 2 (the registry, always-success
    // locked) ignores its witness entirely. Only input 1, the buyer's own
    // sighash-controlled funding cell, needs a real signature.
    let witnesses = vec![escrow_witness_args, buyer_witness, registry_witness];
    let claim_tx = sign_group(claim_tx, &buyer_key, 1, 1, witnesses);

    let tx_hash = send_transaction(&claim_tx);
    println!("Sent CLAIM tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Claimed! The full escrow -> reserve -> claim flow just ran for real, on-chain:");
    println!("  - checks 2/3 (Verifier signature + claim matching): verified by mpesa-escrow's own Lock Script");
    println!("  - check 1 (nullifier): tx_id_hash freshly appended to the live claims-registry cell");
    println!("  - check 4 (reservation): claim only accepted because buyer_lock matched the RESERVE step");
    println!("  - check 5 (seller-ownership): mpesa-escrow cross-checked the escrow cell's real OfferGuard type script");
}
