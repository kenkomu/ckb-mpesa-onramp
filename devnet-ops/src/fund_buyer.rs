//! One-off: send the buyer key (generated lazily by `claim_offer.rs`) a
//! small amount of CKB from the seller/funder key, so it has a live cell
//! of its own to present as proof-of-presence in the CLAIM transaction.

use ckb_types::{
    bytes::Bytes,
    core::TransactionBuilder,
    packed::{CellInput, CellOutput, WitnessArgs},
    prelude::*,
};
use devnet_ops::*;
use k256::ecdsa::SigningKey;
use std::fs;
use std::path::Path;

fn main() {
    let (seller_blake160, seller_key) = load_key(env!("CARGO_MANIFEST_DIR"));
    let seller_lock = sighash_lock(&seller_blake160);

    let buyer_key_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("buyer_key.txt");
    let text = fs::read_to_string(&buyer_key_path)
        .expect("read buyer_key.txt (run claim_offer once first so it generates one)");
    let hex_key = text.trim().strip_prefix("0x").unwrap_or(text.trim()).to_string();
    let bytes = hex::decode(hex_key).unwrap();
    let key = SigningKey::from_bytes(bytes.as_slice().into()).unwrap();
    let compressed = key.verifying_key().to_encoded_point(true);
    let buyer_blake160 = blake160_of_pubkey(compressed.as_bytes());
    let buyer_lock = sighash_lock(&buyer_blake160);

    let (funding_out_point, funding_capacity) = get_one_cell(&seller_lock);
    let funding_input = CellInput::new_builder().previous_output(funding_out_point).build();

    let send_amount = 50_000_000_000u64; // 500 CKB, plenty for a funding/proof-of-presence input
    let fee = 100_000_000u64;
    let buyer_output = CellOutput::new_builder().capacity(send_amount).lock(buyer_lock).build();
    let change_output =
        CellOutput::new_builder().capacity(funding_capacity - send_amount - fee).lock(seller_lock).build();

    let witnesses = vec![WitnessArgs::default().as_bytes()];
    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(buyer_output)
        .output(change_output)
        .outputs_data(vec![Bytes::new(), Bytes::new()].pack())
        .witness(witnesses[0].clone().pack())
        .cell_dep(sighash_cell_dep())
        .build();

    let signed = sign_group(tx, &seller_key, 0, 1, witnesses);
    let tx_hash = send_transaction(&signed);
    println!("Sent fund_buyer tx: {tx_hash}");
    wait_for_tx(&tx_hash, 60);
    println!("Committed. Buyer now has a funded cell.");
}
