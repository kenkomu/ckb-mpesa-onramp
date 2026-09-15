//! Shared helpers for driving the local CKB devnet directly over JSON-RPC,
//! bypassing `ckb-cli` (broken on this machine: missing libssl.so.1.1).
//! Real `ckb_types` (the same crate CKB itself and `ckb-testtool` use), so
//! transaction-building code here reads almost identically to the unit
//! tests in `contract/tests/src/tests.rs` -- the real difference is that
//! everything here has to be genuinely, correctly signed, since there is
//! no ALWAYS_SUCCESS lock or mocked verifier on a real node.

use ckb_types::{
    bytes::Bytes,
    core::{DepType, ScriptHashType, TransactionView},
    packed::{CellDep, OutPoint, Script, WitnessArgs},
    prelude::*,
};
use k256::ecdsa::{RecoveryId, Signature, SigningKey};
use serde_json::{json, Value};

pub const RPC_URL: &str = "http://127.0.0.1:8114";

/// The standard secp256k1_blake160_sighash_all system script's own type
/// hash -- fixed across all CKB chains (mainnet/testnet/dev), since it's
/// part of the genesis block's own system cells and dev chains reuse the
/// identical binary/code_hash.
pub const SIGHASH_CODE_HASH: &str = "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8";

/// The real fix for a bug that cost a long debugging detour: this must be
/// a DEP GROUP, not a direct `code` reference to the sighash binary alone.
/// secp256k1_blake160_sighash_all.c needs its OWN code cell AND a separate
/// precomputed secp256k1 elliptic-curve context/table data cell
/// (`secp256k1_data`) to actually perform verification; referencing just
/// the code cell directly (dep_type "code") let the script be *found* and
/// *executed*, but it failed with a terse `ValidationFailure -101` for
/// every signature tried -- including ones produced by `ckb-cli`'s own
/// battle-tested signer, which is what proved the bug was here, not in
/// any signing math. Confirmed by comparing a real `ckb-cli wallet
/// transfer` transaction's own cell_deps against what was guessed here:
/// it uses `dep_type: "dep_group"` pointing at a bundling cell whose data
/// is an OutPointVec naming both real cells. This devnet's own dep_group
/// outpoint (found the same way, by diffing a known-good transaction --
/// there's no RPC that names it directly).
pub const SIGHASH_DEP_GROUP_TX_HASH: &str = "0xc05f08a40fc9879abb49b5a2c32a1e8bc6fa6ce33ed22d0f96bc405b2e267b70";
pub const SIGHASH_DEP_GROUP_INDEX: u32 = 0;

pub fn sighash_cell_dep() -> CellDep {
    let tx_hash_vec = hex::decode(&SIGHASH_DEP_GROUP_TX_HASH[2..]).expect("valid hex");
    let mut tx_hash = [0u8; 32];
    tx_hash.copy_from_slice(&tx_hash_vec);
    CellDep::new_builder()
        .out_point(OutPoint::new_builder().tx_hash(tx_hash.pack()).index(SIGHASH_DEP_GROUP_INDEX).build())
        .dep_type(DepType::DepGroup)
        .build()
}

pub fn rpc_call(method: &str, params: Value) -> Value {
    let body = json!({"id": 1, "jsonrpc": "2.0", "method": method, "params": params});
    let response_text = ureq::post(RPC_URL)
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
        .unwrap_or_else(|e| panic!("RPC call {method} failed: {e}"))
        .into_string()
        .expect("RPC response was not valid UTF-8");
    let resp: Value = serde_json::from_str(&response_text).expect("RPC response was not valid JSON");
    if let Some(err) = resp.get("error") {
        panic!("RPC error on {method}: {err}");
    }
    resp["result"].clone()
}

pub fn sighash_lock(blake160: &[u8; 20]) -> Script {
    let code_hash_vec = hex::decode(&SIGHASH_CODE_HASH[2..]).expect("valid hex");
    let mut code_hash = [0u8; 32];
    code_hash.copy_from_slice(&code_hash_vec);
    Script::new_builder()
        .code_hash(code_hash.pack())
        .hash_type(ScriptHashType::Type)
        .args(Bytes::from(blake160.to_vec()).pack())
        .build()
}

/// blake160(pubkey) = first 20 bytes of CKB's own personalized blake2b256
/// over the compressed SEC1 pubkey -- the exact derivation
/// secp256k1_blake160_sighash_all expects for its own `args`.
pub fn blake160_of_pubkey(pubkey_compressed: &[u8]) -> [u8; 20] {
    let mut blake2b = ckb_hash::new_blake2b();
    blake2b.update(pubkey_compressed);
    let mut digest = [0u8; 32];
    blake2b.finalize(&mut digest);
    let mut out = [0u8; 20];
    out.copy_from_slice(&digest[0..20]);
    out
}

pub fn blake2b_256(data: &[u8]) -> [u8; 32] {
    let mut blake2b = ckb_hash::new_blake2b();
    blake2b.update(data);
    let mut digest = [0u8; 32];
    blake2b.finalize(&mut digest);
    digest
}

/// Signs a transaction whose inputs `[group_start, group_start +
/// group_input_count)` are all controlled by exactly one
/// secp256k1_blake160_sighash_all lock -- i.e. one script group occupying
/// that contiguous range. `group_start` is almost always 0 (this key's
/// inputs come first), except the CLAIM step, where a custom escrow Lock
/// Script occupies input 0 and the buyer's own sighash-controlled funding
/// input comes after it, as input 1.
///
/// `witnesses` covers every position in the transaction as it will be
/// sent (witnesses[group_start] must be this group's own placeholder
/// WitnessArgs -- content doesn't matter, it gets fully replaced -- and
/// witnesses[group_start+1 .. group_start+group_input_count] are this same
/// group's remaining inputs' witnesses, hashed as-is, not zeroed).
/// Whether any *other* transaction's witnesses (outside this group, e.g.
/// another lock's own witness, or a Type Script's ownership-proof witness
/// at a later index) get folded into this signature's hash depends on
/// whether this group contains the transaction's actual LAST input: CKB's
/// real secp256k1_blake160_sighash_all only pulls in "extra" witnesses
/// (indices >= total input count) for whichever group ends at the last
/// input -- so a group that ISN'T last (e.g. the buyer's group after the
/// escrow's own group, when there happen to be no witnesses past the
/// buyer's own witness anyway) simply doesn't reach past its own inputs.
///
/// Implements the real secp256k1_blake160_sighash_all algorithm from
/// ckb-system-scripts, not an approximation of it -- confirmed correct
/// against the genuine on-chain system script after a debugging detour
/// that turned out to be a missing dep_group, not a signing bug (see
/// `sighash_cell_dep`'s own doc comment).
pub fn sign_group(
    tx: TransactionView,
    signing_key: &SigningKey,
    group_start: usize,
    group_input_count: usize,
    witnesses: Vec<Bytes>,
) -> TransactionView {
    let total_inputs = tx.inputs().len();
    let group_end = group_start + group_input_count;
    assert!(group_input_count >= 1 && group_end <= total_inputs);
    assert!(witnesses.len() >= group_end);

    let tx_hash = tx.hash();

    let zeroed_witness = WitnessArgs::new_builder()
        .lock(Some(Bytes::from(vec![0u8; 65])).pack())
        .build()
        .as_bytes();

    let mut blake2b = ckb_hash::new_blake2b();
    blake2b.update(tx_hash.as_slice());
    blake2b.update(&(zeroed_witness.len() as u64).to_le_bytes());
    blake2b.update(&zeroed_witness);
    // Remaining inputs in this SAME group, hashed as-is, not zeroed --
    // only the group's first witness carries the actual signature.
    for w in &witnesses[group_start + 1..group_end] {
        blake2b.update(&(w.len() as u64).to_le_bytes());
        blake2b.update(w);
    }
    // This group's "extra witnesses" rule only applies if it contains the
    // transaction's actual last input.
    if group_end == total_inputs {
        for w in &witnesses[group_end..] {
            blake2b.update(&(w.len() as u64).to_le_bytes());
            blake2b.update(w);
        }
    }
    let mut digest = [0u8; 32];
    blake2b.finalize(&mut digest);

    let (signature, recid): (Signature, RecoveryId) =
        signing_key.sign_prehash_recoverable(&digest).expect("sign_prehash_recoverable");
    let mut sig_bytes = [0u8; 65];
    sig_bytes[..64].copy_from_slice(&signature.to_bytes());
    sig_bytes[64] = recid.to_byte(); // raw 0-3, NOT Ethereum's +27 offset

    let signed_witness = WitnessArgs::new_builder()
        .lock(Some(Bytes::from(sig_bytes.to_vec())).pack())
        .build()
        .as_bytes();

    let mut final_witnesses: Vec<Bytes> = witnesses;
    final_witnesses[group_start] = signed_witness;

    tx.as_advanced_builder()
        .set_witnesses(final_witnesses.into_iter().map(|w| w.pack()).collect())
        .build()
}

pub fn send_transaction(tx: &TransactionView) -> String {
    let json_tx: ckb_jsonrpc_types::Transaction = tx.data().into();
    let json_tx = serde_json::to_value(json_tx).expect("serialize tx to JSON");
    let result = rpc_call("send_transaction", json!([json_tx, "passthrough"]));
    result.as_str().expect("tx hash string").to_string()
}

/// Decodes a 0x-prefixed hex string into a fixed-size array, panicking
/// with a useful message on any length/format mismatch instead of an
/// opaque slice-copy panic.
pub fn hex32(s: &str) -> [u8; 32] {
    let v = hex::decode(s.trim_start_matches("0x")).unwrap_or_else(|e| panic!("bad hex {s}: {e}"));
    let mut out = [0u8; 32];
    assert_eq!(v.len(), 32, "expected 32 bytes, got {} decoding {s}", v.len());
    out.copy_from_slice(&v);
    out
}

/// Reads `devnet_key.txt` (written by `gen_key`) and returns the signer's
/// blake160 lock args plus the raw signing key.
pub fn load_key(manifest_dir: &str) -> ([u8; 20], SigningKey) {
    let text = std::fs::read_to_string(std::path::Path::new(manifest_dir).join("devnet_key.txt"))
        .expect("read devnet_key.txt (run `cargo run --bin gen_key` first if missing)");
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
    let sk_bytes = hex::decode(private_key_hex.expect("private_key in devnet_key.txt")).unwrap();
    let signing_key = SigningKey::from_bytes(sk_bytes.as_slice().into()).expect("valid secp256k1 key");
    let blake160_vec = hex::decode(blake160_hex.expect("lock_args_blake160 in devnet_key.txt")).unwrap();
    let mut blake160 = [0u8; 20];
    blake160.copy_from_slice(&blake160_vec);
    (blake160, signing_key)
}

/// Fetches exactly one live, type-less cell at `lock` via the Indexer RPC
/// -- enough capacity for a single-input transaction. Panics if none
/// exist (the caller should let the miner run and produce more cellbase
/// cells first).
pub fn get_one_cell(lock: &Script) -> (OutPoint, u64) {
    let script_json = json!({
        "code_hash": format!("0x{}", hex::encode(lock.code_hash().raw_data())),
        "hash_type": "type",
        "args": format!("0x{}", hex::encode(lock.args().raw_data())),
    });
    let result = rpc_call("get_cells", json!([{"script": script_json, "script_type": "lock"}, "asc", "0x1"]));
    let objects = result["objects"].as_array().cloned().unwrap_or_default();
    let obj = objects
        .into_iter()
        .find(|o| o["output"]["type"].is_null())
        .unwrap_or_else(|| panic!("no live type-less cells at this lock -- let the miner run longer"));
    let tx_hash = hex32(obj["out_point"]["tx_hash"].as_str().unwrap());
    let index = u32::from_str_radix(obj["out_point"]["index"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    let capacity = u64::from_str_radix(obj["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    let op = OutPoint::new_builder().tx_hash(tx_hash.pack()).index(index).build();
    (op, capacity)
}

/// Collects live, type-less cells at `lock` until their summed capacity
/// reaches `need`, or panics if the devnet hasn't mined enough yet --
/// callers should just let the miner run longer and retry. Needed
/// whenever a single ~2010 CKB cellbase cell isn't enough on its own
/// (e.g. funding a data cell for a real contract binary).
pub fn collect_cells(lock: &Script, need: u64) -> (Vec<(OutPoint, u64)>, u64) {
    let script_json = json!({
        "code_hash": format!("0x{}", hex::encode(lock.code_hash().raw_data())),
        "hash_type": "type",
        "args": format!("0x{}", hex::encode(lock.args().raw_data())),
    });
    let result = rpc_call("get_cells", json!([{"script": script_json, "script_type": "lock"}, "asc", "0x3e8"]));
    let objects = result["objects"].as_array().cloned().unwrap_or_default();
    let mut collected = Vec::new();
    let mut total = 0u64;
    for obj in objects {
        if total >= need {
            break;
        }
        if !obj["output"]["type"].is_null() {
            continue;
        }
        let tx_hash = hex32(obj["out_point"]["tx_hash"].as_str().unwrap());
        let index =
            u32::from_str_radix(obj["out_point"]["index"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
        let capacity =
            u64::from_str_radix(obj["output"]["capacity"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
        let op = OutPoint::new_builder().tx_hash(tx_hash.pack()).index(index).build();
        collected.push((op, capacity));
        total += capacity;
    }
    if total < need {
        panic!("not enough mined capacity yet: have {total} shannon, need {need} shannon -- let the miner run longer");
    }
    (collected, total)
}

/// A plain `dep_type: code` cell_dep pointing at one of our own deployed
/// binaries (from `deploy.rs`'s `deployed.json`), used with hash_type
/// Data1 (their code_hash is `blake2b_256` of the raw binary bytes --
/// same convention `CellOutput::calc_data_hash` uses, and the same
/// personalized blake2b the whole chain uses everywhere else).
pub fn deployed_binary_cell_dep(deploy_tx_hash: &str, index: u32) -> CellDep {
    let tx_hash = hex32(deploy_tx_hash);
    CellDep::new_builder()
        .out_point(OutPoint::new_builder().tx_hash(tx_hash.pack()).index(index).build())
        .dep_type(DepType::Code)
        .build()
}

/// The SECP256K1ETH-style signer mpesa-escrow's and offer-guard's own
/// trust model expects for claim/ownership signatures -- secp256k1 with
/// Keccak256 hashing, `r || s || v` (v = raw recovery id + 27, matching
/// Solidity's `ecrecover`). Distinct from `sign_group`'s CKB sighash
/// scheme above, which is a different curve encoding entirely (raw
/// recovery id, no +27, blake2b not Keccak256) -- these two signing
/// schemes exist for genuinely different roles (authorizing a CKB cell
/// spend, vs. a trusted off-chain Verifier attesting to a real-world
/// fact) and must not be confused with each other.
pub struct EthSigner {
    pub key: SigningKey,
}

impl EthSigner {
    pub fn random() -> Self {
        Self { key: SigningKey::random(&mut rand::thread_rng()) }
    }

    pub fn address(&self) -> [u8; 20] {
        use sha3::{Digest, Keccak256};
        let encoded = self.key.verifying_key().to_encoded_point(false);
        let pubkey_bytes = &encoded.as_bytes()[1..];
        let digest = Keccak256::digest(pubkey_bytes);
        let mut address = [0u8; 20];
        address.copy_from_slice(&digest[12..32]);
        address
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 65] {
        use sha3::{Digest, Keccak256};
        let digest = Keccak256::digest(message);
        let (signature, recid): (Signature, RecoveryId) =
            self.key.sign_prehash_recoverable(&digest).expect("sign_prehash_recoverable");
        let mut sig = [0u8; 65];
        sig[..64].copy_from_slice(&signature.to_bytes());
        sig[64] = recid.to_byte() + 27;
        sig
    }
}

pub fn wait_for_tx(tx_hash: &str, max_wait_secs: u64) {
    for _ in 0..(max_wait_secs * 2) {
        let result = rpc_call("get_transaction", json!([tx_hash]));
        if let Some(status) = result.get("tx_status").and_then(|s| s.get("status")) {
            let status = status.as_str().unwrap_or("");
            if status == "committed" {
                return;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    panic!("transaction {tx_hash} not committed within {max_wait_secs}s");
}
