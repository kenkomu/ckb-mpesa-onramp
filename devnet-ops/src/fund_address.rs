//! One-off: send a given private key's own sighash lock some CKB from
//! the seller/funder key. Used to fund the browser-wallet key generated
//! by the JS verification script (assets/js/verify_flows.mjs) -- not
//! part of the shipped app, just a devnet testing convenience.
//! Usage: cargo run --bin fund_address -- <0x-prefixed 32-byte private key>

use ckb_types::{bytes::Bytes, core::TransactionBuilder, packed::{CellInput, CellOutput, WitnessArgs}, prelude::*};
use devnet_ops::*;
use k256::ecdsa::SigningKey;

fn main() {
    let target_key_hex = std::env::args().nth(1).expect("usage: fund_address <0x-prefixed 32-byte private key>");
    let target_key_bytes = hex::decode(target_key_hex.trim_start_matches("0x")).expect("valid hex");
    let target_key = SigningKey::from_bytes(target_key_bytes.as_slice().into()).expect("valid secp256k1 key");
    let target_compressed = target_key.verifying_key().to_encoded_point(true);
    let target_blake160 = blake160_of_pubkey(target_compressed.as_bytes());
    let target_lock = sighash_lock(&target_blake160);
    println!("Funding blake160: 0x{}", hex::encode(target_blake160));

    let (blake160, signing_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let lock = sighash_lock(&blake160);

    let (funding_out_point, funding_capacity) = get_one_cell(&lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    let send_amount = 50_000_000_000u64; // 500 CKB
    let fee = 100_000_000u64;
    let target_output = CellOutput::new_builder().capacity(send_amount).lock(target_lock).build();
    let change_output =
        CellOutput::new_builder().capacity(funding_capacity - send_amount - fee).lock(lock).build();

    let witnesses = vec![WitnessArgs::default().as_bytes()];
    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(target_output)
        .output(change_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witness(witnesses[0].clone().pack())
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &signing_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent fund_address tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed.");
}
