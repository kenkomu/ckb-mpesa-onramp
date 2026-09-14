use ckb_testtool::ckb_types::{
    bytes::Bytes,
    core::{TransactionBuilder, TransactionView},
    packed::{CellDep, CellInput, CellOutput, OutPoint, Script, WitnessArgs},
    prelude::*,
};
use ckb_testtool::context::Context;
use k256::ecdsa::{Signature, SigningKey};
use sha3::{Digest, Keccak256};

const MAX_CYCLES: u64 = 10_000_000;

fn assert_script_error(err: ckb_testtool::ckb_error::Error, err_code: i8) {
    let error_string = err.to_string();
    let code = err_code.to_string();
    assert!(
        error_string.contains(&format!("error code {code} "))
            || error_string.contains(&format!("code {code} "))
            || error_string.contains(&format!("code {code})"))
            || error_string.contains(&format!("exit code {code}")),
        "error_string: {error_string}, expected_error_code: {code}"
    );
}

/// Mirrors TLSNotary's own `Secp256k1EthSigner`
/// (tlsn's crates/attestation/src/signing.rs): Keccak256-prehash the
/// message, sign_prehash_recoverable, then append `recid + 27` as the
/// 65th byte -- the exact `r || s || v` shape Solidity's ecrecover expects,
/// and the shape this contract's `recover_eth_address` decodes.
struct Signer {
    key: SigningKey,
}

impl Signer {
    fn random() -> Self {
        Self {
            key: SigningKey::random(&mut rand::thread_rng()),
        }
    }

    /// The 20-byte Ethereum-style address this signer's key recovers to --
    /// same derivation as the contract: Keccak256(uncompressed pubkey
    /// minus the 0x04 prefix), last 20 bytes.
    fn address(&self) -> [u8; 20] {
        let verifying_key = self.key.verifying_key();
        let encoded = verifying_key.to_encoded_point(false);
        let pubkey_bytes = &encoded.as_bytes()[1..];
        let digest = Keccak256::digest(pubkey_bytes);
        let mut address = [0u8; 20];
        address.copy_from_slice(&digest[12..32]);
        address
    }

    fn sign(&self, message: &[u8]) -> [u8; 65] {
        let digest = Keccak256::digest(message);
        let (signature, recid): (Signature, _) = self
            .key
            .sign_prehash_recoverable(&digest)
            .expect("sign_prehash_recoverable");
        let mut sig = [0u8; 65];
        sig[..64].copy_from_slice(&signature.to_bytes());
        sig[64] = recid.to_byte() + 27;
        sig
    }
}

/// Builds a claim message the same way the contract reconstructs it:
/// tx_id_hash(32) || recipient_hash(32) || amount_le(8).
fn claim_message(tx_id_hash: &[u8; 32], recipient_hash: &[u8; 32], amount: i64) -> [u8; 72] {
    let mut message = [0u8; 72];
    message[0..32].copy_from_slice(tx_id_hash);
    message[32..64].copy_from_slice(recipient_hash);
    message[64..72].copy_from_slice(&amount.to_le_bytes());
    message
}

fn build_args(
    witness_address: &[u8; 20],
    recipient_hash: &[u8; 32],
    amount: i64,
    registry_type_hash: &[u8; 32],
) -> Bytes {
    let mut args = Vec::with_capacity(92);
    args.extend_from_slice(witness_address);
    args.extend_from_slice(recipient_hash);
    args.extend_from_slice(&amount.to_le_bytes());
    args.extend_from_slice(registry_type_hash);
    Bytes::from(args)
}

fn build_witness(
    tx_id_hash: &[u8; 32],
    recipient_hash: &[u8; 32],
    amount: i64,
    signature: &[u8; 65],
) -> Bytes {
    let mut witness = Vec::with_capacity(137);
    witness.extend_from_slice(tx_id_hash);
    witness.extend_from_slice(recipient_hash);
    witness.extend_from_slice(&amount.to_le_bytes());
    witness.extend_from_slice(signature);
    Bytes::from(witness)
}

/// Deploys mpesa-escrow as an input cell's lock script AND, in the SAME
/// transaction, spends the current live registry cell (from a prior
/// `mint_registry` call) to append `registering_hash` to its data --
/// exactly the shape a real buyer-claim transaction has. Tests that want to
/// exercise the nullifier-mismatch/missing-update paths pass a
/// `registering_hash` different from (or absent from) the claim's own
/// `tx_id_hash` inside `witness_lock`.
///
/// The escrow input cell carries `reserved_by_lock_hash` (32 bytes) as its
/// reservation state -- check 4 -- and a THIRD input, locked by
/// `claimant_lock`, is added to the transaction. When `reserved_by_lock_hash`
/// equals `claimant_lock`'s own hash (the normal, honest case), that lock
/// hash is actually present among the tx's other inputs, satisfying the
/// "claimant is the party who reserved it" check; tests that want to prove
/// the check actually bites pass a `reserved_by_lock_hash` that does NOT
/// match `claimant_lock`. The escrowed capacity is sent to `claimant_lock`
/// in the output (no GroupOutput cell at all), matching how a real claim
/// actually moves funds.
#[allow(clippy::too_many_arguments)]
fn build_escrow_claim_tx(
    context: &mut Context,
    witness_address: &[u8; 20],
    recipient_hash: &[u8; 32],
    amount: i64,
    registry_out_point: &OutPoint,
    registry_cell: &CellOutput,
    registry_current_data: &[u8],
    registering_hash: Option<&[u8; 32]>,
    witness_lock: Bytes,
    claimant_lock: &Script,
) -> TransactionView {
    let claimant_lock_hash: [u8; 32] = claimant_lock.calc_script_hash().unpack();
    build_escrow_claim_tx_with_reservation(
        context,
        witness_address,
        recipient_hash,
        amount,
        registry_out_point,
        registry_cell,
        registry_current_data,
        registering_hash,
        witness_lock,
        claimant_lock,
        &claimant_lock_hash,
    )
}

/// Same as `build_escrow_claim_tx`, but lets the reservation hash stored on
/// the escrow cell be set independently of `claimant_lock`'s real hash --
/// needed to prove `ERROR_NOT_RESERVED_BY_CLAIMANT` actually fires.
#[allow(clippy::too_many_arguments)]
fn build_escrow_claim_tx_with_reservation(
    context: &mut Context,
    witness_address: &[u8; 20],
    recipient_hash: &[u8; 32],
    amount: i64,
    registry_out_point: &OutPoint,
    registry_cell: &CellOutput,
    registry_current_data: &[u8],
    registering_hash: Option<&[u8; 32]>,
    witness_lock: Bytes,
    claimant_lock: &Script,
    reserved_by_lock_hash: &[u8; 32],
) -> TransactionView {
    let out_point = context.deploy_cell_by_name("mpesa-escrow");
    let registry_type_hash: [u8; 32] = registry_cell
        .type_()
        .to_opt()
        .expect("registry cell must carry a type script")
        .calc_script_hash()
        .unpack();
    let args = build_args(witness_address, recipient_hash, amount, &registry_type_hash);
    let lock_script = context.build_script(&out_point, args).expect("script");

    let escrow_input_out_point = context.create_cell(
        CellOutput::new_builder()
            .capacity(100_000_000_000u64)
            .lock(lock_script.clone())
            .build(),
        Bytes::from(reserved_by_lock_hash.to_vec()),
    );
    let escrow_input = CellInput::new_builder()
        .previous_output(escrow_input_out_point)
        .build();
    let escrow_payout_output = CellOutput::new_builder()
        .capacity(100_000_000_000u64)
        .lock(claimant_lock.clone())
        .build();

    // The claimant's own funding input -- its presence, locked by
    // `claimant_lock`, is what the contract checks against the reservation.
    let claimant_funding_out_point = context.create_cell(
        CellOutput::new_builder()
            .capacity(50_000_000_000u64)
            .lock(claimant_lock.clone())
            .build(),
        Bytes::new(),
    );
    let claimant_input = CellInput::new_builder()
        .previous_output(claimant_funding_out_point)
        .build();
    let claimant_change_output = CellOutput::new_builder()
        .capacity(50_000_000_000u64)
        .lock(claimant_lock.clone())
        .build();

    let registry_input_out_point =
        context.create_cell(registry_cell.clone(), Bytes::from(registry_current_data.to_vec()));
    let registry_input = CellInput::new_builder()
        .previous_output(registry_input_out_point)
        .build();
    let mut new_registry_data = registry_current_data.to_vec();
    if let Some(hash) = registering_hash {
        new_registry_data.extend_from_slice(hash);
    }

    let escrow_witness_args = WitnessArgs::new_builder()
        .lock(Some(witness_lock).pack())
        .build();
    let empty_witness_args = WitnessArgs::default();

    let cell_deps = vec![
        CellDep::new_builder().out_point(out_point).build(),
        CellDep::new_builder().out_point(registry_out_point.clone()).build(),
    ];
    let tx = TransactionBuilder::default()
        .input(escrow_input)
        .input(claimant_input)
        .input(registry_input)
        .output(escrow_payout_output)
        .output(claimant_change_output)
        .output(registry_cell.clone())
        .outputs_data(vec![Bytes::new(), Bytes::new(), Bytes::from(new_registry_data)].pack())
        .witness(escrow_witness_args.as_bytes().pack())
        .witness(empty_witness_args.clone().as_bytes().pack())
        .witness(empty_witness_args.as_bytes().pack())
        .cell_deps(cell_deps)
        .build();
    context.complete_tx(tx)
}

/// Deploys ALWAYS_SUCCESS as a stand-in "claimant" lock script -- the
/// buyer's own wallet lock, in a real transaction. Distinct calls with
/// distinct `salt` args produce distinct lock hashes, so tests can tell an
/// authorized claimant apart from an unrelated third party.
fn claimant_lock(context: &mut Context, salt: u8) -> Script {
    let out_point = context.deploy_cell(ckb_testtool::builtin::ALWAYS_SUCCESS.clone());
    context
        .build_script(&out_point, Bytes::from(vec![salt]))
        .expect("script")
}

#[test]
fn test_happy_path_valid_claim_unlocks_and_registers_nullifier() {
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[], // registry starts empty
        Some(&tx_id_hash),
        witness,
        &buyer_lock,
    );
    context.verify_tx(&tx, MAX_CYCLES).expect("pass verification");
}

#[test]
fn test_wrong_signer_rejected() {
    // Signed by an attacker's key, not the address baked into the cell's args.
    let trusted_signer = Signer::random();
    let attacker_signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = attacker_signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &trusted_signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 9); // ERROR_WITNESS_ADDRESS_MISMATCH
}

#[test]
fn test_tampered_amount_rejected() {
    // Signature is valid for 25_000, but the witness claims a different
    // amount -- the recovered address won't match what actually signed
    // this modified message, since the signature covers the amount too.
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let signed_amount: i64 = 25_000;
    let claimed_amount: i64 = 250_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, signed_amount);
    let signature = signer.sign(&message);
    // Witness claims a different amount than what was actually signed.
    let witness = build_witness(&tx_id_hash, &recipient_hash, claimed_amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        signed_amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 9); // recovers to a different address than expected
}

#[test]
fn test_wrong_recipient_rejected() {
    let signer = Signer::random();
    let expected_recipient_hash = [7u8; 32];
    let different_recipient_hash = [8u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    // Signed for a different recipient than the cell expects.
    let message = claim_message(&tx_id_hash, &different_recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &different_recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &expected_recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 10); // ERROR_RECIPIENT_MISMATCH
}

#[test]
fn test_malformed_witness_length_rejected() {
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;
    let witness = Bytes::from(vec![0u8; 10]); // way too short

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 6); // ERROR_WITNESS_LEN
}

#[test]
fn test_claim_not_registered_in_this_tx_rejected() {
    // A valid signature and claim, but the transaction doesn't actually
    // append this tx_id to the registry at all -- check 1 must catch this
    // even though checks 2 and 3 (signature, claim matching) pass cleanly.
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        None, // registry is spent-and-recreated but nothing is appended
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 12); // ERROR_REGISTRY_NOT_FOUND (registry rejects the malformed update itself, so the escrow's own check never even gets the chance to fire independently -- but either way this transaction must fail)
}

#[test]
fn test_registering_a_different_claim_rejected() {
    // The registry update is real and well-formed, but it registers a
    // DIFFERENT tx_id than the one this specific claim actually proves --
    // e.g. trying to piggyback an unrelated valid claim's registration.
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let unrelated_tx_id_hash = [99u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&unrelated_tx_id_hash), // registers a different claim entirely
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 13); // ERROR_REGISTRY_NOT_REGISTERING_THIS_CLAIM
}

#[test]
fn test_replaying_same_claim_across_transactions_rejected() {
    // The real end-to-end nullifier property: a genuinely valid claim
    // unlocks its own escrow cell once; replaying the SAME tx_id_hash
    // against a SECOND, different escrow offer in a later transaction must
    // fail, because the registry cell (now containing that hash) rejects
    // appending a duplicate.
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, registry_type_script, registry_cell, _) = mint_registry(&mut context);
    let buyer_lock = claimant_lock(&mut context, 1);

    let first_tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness.clone(),
        &buyer_lock,
    );
    context.verify_tx(&first_tx, MAX_CYCLES).expect("first claim should pass");

    // The registry cell now (conceptually) holds [tx_id_hash]. Build a
    // second escrow + claim referencing that updated registry state.
    let registry_after_first_claim = registry_type_script; // same type script/identity
    let _ = registry_after_first_claim;
    let updated_registry_data = tx_id_hash.to_vec();
    let second_tx = build_escrow_claim_tx(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &updated_registry_data,
        Some(&tx_id_hash), // replaying the exact same claim
        witness,
        &buyer_lock,
    );
    let err = context.verify_tx(&second_tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 8); // ERROR_DUPLICATE_CLAIM, from claims-registry itself
}

// ============================================================================
// Reservation (check 4) -- the ghosting-prevention half only. See the
// module doc comment in mpesa-escrow/src/main.rs for what's deliberately
// NOT covered (expiry/reopen, which needs `since` timelocks).
// ============================================================================

/// Builds a RESERVE transaction: an open escrow cell (empty data) becomes
/// reserved (32-byte lock-hash data), same lock script both sides, no
/// witness needed -- reservation is deliberately unauthorized.
fn build_reserve_tx(context: &mut Context, reserved_by_lock_hash: &[u8; 32]) -> TransactionView {
    let out_point = context.deploy_cell_by_name("mpesa-escrow");
    let registry_type_hash = [0u8; 32]; // irrelevant to the RESERVE path
    let args = build_args(&[0u8; 20], &[0u8; 32], 0, &registry_type_hash);
    let lock_script = context.build_script(&out_point, args).expect("script");

    let escrow_input_out_point = context.create_cell(
        CellOutput::new_builder()
            .capacity(100_000_000_000u64)
            .lock(lock_script.clone())
            .build(),
        Bytes::new(), // open, unreserved
    );
    let escrow_input = CellInput::new_builder()
        .previous_output(escrow_input_out_point)
        .build();
    let escrow_output = CellOutput::new_builder()
        .capacity(100_000_000_000u64)
        .lock(lock_script)
        .build();

    let cell_deps = vec![CellDep::new_builder().out_point(out_point).build()];
    let tx = TransactionBuilder::default()
        .input(escrow_input)
        .output(escrow_output)
        .outputs_data(vec![Bytes::from(reserved_by_lock_hash.to_vec())].pack())
        .cell_deps(cell_deps)
        .build();
    context.complete_tx(tx)
}

#[test]
fn test_reserve_transition_open_offer_to_reserved() {
    // Anyone may reserve an open offer -- no signature or authorization
    // needed for this transition, by design.
    let mut context = Context::default();
    let reserved_by_lock_hash = [3u8; 32];
    let tx = build_reserve_tx(&mut context, &reserved_by_lock_hash);
    context.verify_tx(&tx, MAX_CYCLES).expect("reserve should pass");
}

#[test]
fn test_reserve_transition_rejects_malformed_output_data() {
    // Output data isn't a well-formed 32-byte reservation -- neither a
    // valid RESERVE nor a valid CLAIM (empty input rules out CLAIM).
    let mut context = Context::default();
    let out_point = context.deploy_cell_by_name("mpesa-escrow");
    let registry_type_hash = [0u8; 32];
    let args = build_args(&[0u8; 20], &[0u8; 32], 0, &registry_type_hash);
    let lock_script = context.build_script(&out_point, args).expect("script");

    let escrow_input_out_point = context.create_cell(
        CellOutput::new_builder()
            .capacity(100_000_000_000u64)
            .lock(lock_script.clone())
            .build(),
        Bytes::new(),
    );
    let escrow_input = CellInput::new_builder()
        .previous_output(escrow_input_out_point)
        .build();
    let escrow_output = CellOutput::new_builder()
        .capacity(100_000_000_000u64)
        .lock(lock_script)
        .build();

    let cell_deps = vec![CellDep::new_builder().out_point(out_point).build()];
    let tx = TransactionBuilder::default()
        .input(escrow_input)
        .output(escrow_output)
        .outputs_data(vec![Bytes::from(vec![1u8; 10])].pack()) // wrong length
        .cell_deps(cell_deps)
        .build();
    let tx = context.complete_tx(tx);
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 15); // ERROR_UNSUPPORTED_STRUCTURE
}

#[test]
fn test_claim_by_non_reserving_party_rejected() {
    // A valid signature, valid claim, valid nullifier registration -- but
    // the escrow cell was reserved by someone else's lock hash, and none of
    // this transaction's other inputs are locked by that hash. A different
    // buyer racing in with a technically-valid claim must still be rejected.
    let signer = Signer::random();
    let recipient_hash = [7u8; 32];
    let tx_id_hash = [9u8; 32];
    let amount: i64 = 25_000;

    let message = claim_message(&tx_id_hash, &recipient_hash, amount);
    let signature = signer.sign(&message);
    let witness = build_witness(&tx_id_hash, &recipient_hash, amount, &signature);

    let mut context = Context::default();
    let (registry_out_point, _, registry_cell, _) = mint_registry(&mut context);
    let actual_reserver_lock_hash = [42u8; 32]; // not present among this tx's inputs
    let claimant_lock = claimant_lock(&mut context, 1);
    let tx = build_escrow_claim_tx_with_reservation(
        &mut context,
        &signer.address(),
        &recipient_hash,
        amount,
        &registry_out_point,
        &registry_cell,
        &[],
        Some(&tx_id_hash),
        witness,
        &claimant_lock,
        &actual_reserver_lock_hash,
    );
    let err = context.verify_tx(&tx, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 16); // ERROR_NOT_RESERVED_BY_CLAIMANT
}

/// Derives a Type ID mint value the exact same way ckb_std::type_id::check_type_id
/// expects it: blake2b(first tx CellInput || own output index), using CKB's own
/// blake2b personalization (ckb_testtool::ckb_hash::new_blake2b(), not a generic
/// blake2b_256 -- this is confirmed-correct, reused verbatim from
/// scripting-basics-labs' own typeid tests).
fn type_id_args_for_first_input(input: &CellInput, output_index: u64) -> Bytes {
    let mut blake2b = ckb_testtool::ckb_hash::new_blake2b();
    blake2b.update(input.as_slice());
    blake2b.update(&output_index.to_le_bytes());
    let mut ret = [0u8; 32];
    blake2b.finalize(&mut ret);
    Bytes::from(ret.to_vec())
}

// ============================================================================
// ClaimsRegistry -- the nullifier. Type ID gives the registry cell a stable
// identity; check_type_id's own mint/transfer distinction handles that part
// for free. What's tested here is the logic ON TOP of Type ID: mint must
// start empty, an update must append exactly one 32-byte hash without
// touching the existing prefix, and appending a hash that's already present
// must be rejected.
// ============================================================================

/// Deploys claims-registry with ALWAYS_SUCCESS as its lock, minting a fresh
/// registry cell (empty data) as an output with a real Type ID derived from
/// the first input's outpoint -- the same mint shape typeid's own tests use.
fn mint_registry(context: &mut Context) -> (OutPoint, Script, CellOutput, Bytes) {
    let out_point = context.deploy_cell_by_name("claims-registry");
    let out_point_always_success = context.deploy_cell(ckb_testtool::builtin::ALWAYS_SUCCESS.clone());
    let lock_script = context
        .build_script(&out_point_always_success, Default::default())
        .expect("script");

    let funding_out_point = context.create_cell(
        CellOutput::new_builder()
            .capacity(200_000_000_000u64)
            .lock(lock_script.clone())
            .build(),
        Bytes::new(),
    );
    let funding_input = CellInput::new_builder()
        .previous_output(funding_out_point)
        .build();

    let registry_type_script = context
        .build_script(&out_point, type_id_args_for_first_input(&funding_input, 0))
        .expect("script");

    let registry_output = CellOutput::new_builder()
        .capacity(200_000_000_000u64)
        .lock(lock_script.clone())
        .type_(Some(registry_type_script.clone()).pack())
        .build();

    let cell_deps = vec![
        CellDep::new_builder().out_point(out_point.clone()).build(),
        CellDep::new_builder().out_point(out_point_always_success).build(),
    ];
    let tx = TransactionBuilder::default()
        .input(funding_input)
        .output(registry_output.clone())
        .outputs_data(vec![Bytes::new()].pack())
        .cell_deps(cell_deps)
        .build();
    let tx = context.complete_tx(tx);
    context.verify_tx(&tx, MAX_CYCLES).expect("mint should pass");

    (out_point, registry_type_script, registry_output, lock_script.as_bytes())
}

#[test]
fn test_registry_mint_starts_empty() {
    let mut context = Context::default();
    mint_registry(&mut context); // panics via .expect() if this fails
}

#[test]
fn test_registry_update_appends_one_hash() {
    let mut context = Context::default();
    let (registry_out_point, registry_type_script, registry_cell, _) = mint_registry(&mut context);
    let out_point_always_success = context.deploy_cell(ckb_testtool::builtin::ALWAYS_SUCCESS.clone());
    let lock_script = context
        .build_script(&out_point_always_success, Default::default())
        .expect("script");

    let registry_input_out_point = context.create_cell(registry_cell.clone(), Bytes::new());
    let registry_input = CellInput::new_builder()
        .previous_output(registry_input_out_point)
        .build();
    let updated_output = registry_cell
        .clone()
        .as_builder()
        .lock(lock_script)
        .build();

    let cell_deps = vec![
        CellDep::new_builder().out_point(registry_out_point).build(),
        CellDep::new_builder().out_point(out_point_always_success).build(),
    ];
    let new_hash = [1u8; 32];
    let tx = TransactionBuilder::default()
        .input(registry_input)
        .output(updated_output)
        .outputs_data(vec![Bytes::from(new_hash.to_vec())].pack())
        .cell_deps(cell_deps)
        .build();
    let tx = context.complete_tx(tx);
    context.verify_tx(&tx, MAX_CYCLES).expect("first claim should pass");

    let _ = registry_type_script; // kept for clarity of what's under test
}

#[test]
fn test_registry_duplicate_claim_rejected() {
    let mut context = Context::default();
    let (registry_out_point, _registry_type_script, registry_cell, _) = mint_registry(&mut context);
    let out_point_always_success = context.deploy_cell(ckb_testtool::builtin::ALWAYS_SUCCESS.clone());
    let lock_script = context
        .build_script(&out_point_always_success, Default::default())
        .expect("script");

    // First claim: registry goes from [] to [hash].
    let existing_hash = [1u8; 32];
    let after_first_claim = registry_cell.clone().as_builder().lock(lock_script.clone()).build();
    let input_out_point_1 = context.create_cell(registry_cell.clone(), Bytes::new());
    let input_1 = CellInput::new_builder().previous_output(input_out_point_1).build();
    let cell_deps = vec![
        CellDep::new_builder().out_point(registry_out_point.clone()).build(),
        CellDep::new_builder().out_point(out_point_always_success.clone()).build(),
    ];
    let tx1 = TransactionBuilder::default()
        .input(input_1)
        .output(after_first_claim.clone())
        .outputs_data(vec![Bytes::from(existing_hash.to_vec())].pack())
        .cell_deps(cell_deps.clone())
        .build();
    let tx1 = context.complete_tx(tx1);
    context.verify_tx(&tx1, MAX_CYCLES).expect("first claim should pass");

    // Second claim attempts to append the SAME hash again -- must be rejected.
    let input_out_point_2 = context.create_cell(after_first_claim.clone(), Bytes::from(existing_hash.to_vec()));
    let input_2 = CellInput::new_builder().previous_output(input_out_point_2).build();
    let mut replayed_data = existing_hash.to_vec();
    replayed_data.extend_from_slice(&existing_hash); // appending the duplicate
    let tx2 = TransactionBuilder::default()
        .input(input_2)
        .output(after_first_claim)
        .outputs_data(vec![Bytes::from(replayed_data)].pack())
        .cell_deps(cell_deps)
        .build();
    let tx2 = context.complete_tx(tx2);
    let err = context.verify_tx(&tx2, MAX_CYCLES).unwrap_err();
    assert_script_error(err, 8); // ERROR_DUPLICATE_CLAIM
}
