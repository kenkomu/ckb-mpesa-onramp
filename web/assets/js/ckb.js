// Bitshada's browser-side transaction building, using the real CCC SDK --
// the same library a real JoyID/CCC wallet-connect integration would use.
//
// "Wallet connect" here means ccc.SignerCkbPrivateKey with a randomly
// generated key persisted in localStorage, NOT a real JoyID popup. JoyID
// is a hosted wallet service that has no way to recognize a private local
// devnet chain at all, so it simply can't be used against this devnet --
// see the Bitshada plan's own notes on this. The Signer interface is the
// same either way, so swapping in real JoyID later (once this deploys
// somewhere JoyID's own infrastructure reaches, i.e. testnet/mainnet)
// only touches getSigner() below; every transaction-building function is
// already written against the generic Signer/Client interface.
//
// Byte layouts here mirror contract/contracts/{mpesa-escrow,offer-guard}
// exactly -- see each contract's own doc comment for the authoritative
// version; this is a second, independent implementation of the same
// wire format, not a shared source of truth with the Rust one.

import { ccc } from "@ckb-ccc/ccc";

const WALLET_KEY_STORAGE = "bitshada_wallet_key";
const FEE_RATE = 2000n; // shannons per 1000 bytes -- 2x the observed devnet minimum, for headroom

let cachedConfig = null;

async function getConfig() {
  if (!cachedConfig) {
    const res = await fetch("/api/config");
    if (!res.ok) throw new Error("failed to load /api/config");
    cachedConfig = await res.json();
  }
  return cachedConfig;
}

function getClient(config) {
  // A generic JSON-RPC client pointed at our own devnet -- ClientPublicTestnet
  // is just a concrete ClientJsonRpc subclass; `fallbacks: []` stops it from
  // ever trying real testnet URLs if our devnet call fails. `scripts`
  // overrides `ClientPublicTestnet`'s own DEFAULT known-script registry
  // (real testnet outpoints) for Secp256k1Blake160 specifically -- without
  // this, `completeFeeChangeToOutput`'s internal size/cell_dep estimation
  // silently pulls in testnet's own sighash cell_dep outpoint instead of
  // our devnet's, producing a transaction the devnet node rejects with
  // "Unknown OutPoint" (found the hard way, cross-checking against a real
  // send_transaction failure -- not a guess).
  const sighashScriptInfo = {
    codeHash: config.sighash_code_hash,
    hashType: "type",
    cellDeps: [
      {
        cellDep: {
          outPoint: { txHash: config.sighash_dep_group.tx_hash, index: config.sighash_dep_group.index },
          depType: "depGroup",
        },
      },
    ],
  };
  // ClientPublicTestnet's OWN default `scripts` registry (real testnet
  // outpoints for every KnownScript) isn't reachable from outside the
  // SDK to merge with, and various internal SDK code paths (findCells's
  // own AnyoneCanPay check, fee/DAO-profit estimation, ...) look up
  // OTHER known scripts too, throwing if any single one is missing --
  // found each one the hard way, via real send/complete failures, not
  // guessed up front. Every OTHER KnownScript gets a genuinely inert
  // placeholder (a code_hash that matches nothing real) so lookups
  // resolve instead of throwing but never actually find a cell --
  // reusing sighashScriptInfo here directly was tried first and caused a
  // real, silent bug: findCells enumerates the wallet's cells once per
  // "known address variant" (secp256k1 AND every placeholder alike, all
  // resolving to the identical script), so the SAME live cell got
  // collected twice, adding a duplicated input the chain rejected as a
  // "Dead" outpoint (a transaction spending the same cell as two of its
  // own inputs) -- caught via a real send_transaction failure, not by
  // reasoning about it up front.
  const inertScriptInfo = { codeHash: `0x${"00".repeat(32)}`, hashType: "data1", cellDeps: [] };
  const scripts = Object.fromEntries(Object.values(ccc.KnownScript).map((name) => [name, inertScriptInfo]));
  scripts[ccc.KnownScript.Secp256k1Blake160] = sighashScriptInfo;
  return new ccc.ClientPublicTestnet({ url: config.rpc_url, fallbacks: [], scripts });
}

function getOrCreateWalletKey() {
  let key = localStorage.getItem(WALLET_KEY_STORAGE);
  if (!key) {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    key = "0x" + [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    localStorage.setItem(WALLET_KEY_STORAGE, key);
  }
  return key;
}

async function getSigner() {
  const config = await getConfig();
  const client = getClient(config);
  const signer = new ccc.SignerCkbPrivateKey(client, getOrCreateWalletKey());
  return { signer, client, config };
}

export async function walletInfo() {
  const { signer } = await getSigner();
  const addressObj = await signer.getAddressObjSecp256k1();
  return {
    lockHash: addressObj.script.hash(),
    address: addressObj.toString(),
  };
}

// ---- byte-level helpers matching the contracts' own layouts ----

function concatHex(...parts) {
  return ccc.hexFrom(ccc.bytesConcat(...parts.map((p) => ccc.bytesFrom(p))));
}

function amountToLeHex8(amount) {
  const buf = new ArrayBuffer(8);
  new DataView(buf).setBigInt64(0, BigInt(amount), true);
  return ccc.hexFrom(new Uint8Array(buf));
}

function scriptFrom(codeHash, hashType, args) {
  return ccc.Script.from({ codeHash, hashType, args });
}

/**
 * Every OutPoint this module reads back from OUR OWN JSON API (offers,
 * registry) arrives snake_case (`{tx_hash, index}`, matching CKB's own
 * RPC/molecule field naming, which Web.Ckb.Offers/Registry pass through
 * largely as-is) -- CCC's own OutPointLike expects camelCase
 * (`{txHash, index}`). Converting once here, rather than inline at each
 * call site, after a real molecule-decoding crash traced back to exactly
 * this mismatch.
 */
function outPointFrom(apiOutPoint) {
  return { txHash: apiOutPoint.tx_hash ?? apiOutPoint.txHash, index: apiOutPoint.index };
}

/** Rebuilds mpesa-escrow's own 124-byte lock args from an offer's decoded API fields. */
function escrowArgsFromOffer(offer) {
  return concatHex(
    offer.witness_address,
    offer.recipient_hash,
    amountToLeHex8(offer.amount),
    offer.registry_type_hash,
    offer.offer_guard_type_hash,
  );
}

/** Rebuilds offer-guard's own 52-byte type args from an offer's decoded API fields. */
function guardArgsFromOffer(offer) {
  return concatHex(offer.witness_address, offer.recipient_hash);
}

function sighashCellDep(config) {
  return ccc.CellDep.from({
    outPoint: { txHash: config.sighash_dep_group.tx_hash, index: config.sighash_dep_group.index },
    depType: "depGroup",
  });
}

function contractCellDep(entry) {
  return ccc.CellDep.from({
    outPoint: { txHash: entry.cell_dep.tx_hash, index: entry.cell_dep.index },
    depType: "code",
  });
}

async function postJson(url, body) {
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`${url} failed: ${await res.text()}`);
  return res.json();
}

async function getJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} failed: ${await res.text()}`);
  return res.json();
}

function numHex(n) {
  return "0x" + BigInt(n).toString(16);
}

function scriptToRpc(script) {
  if (!script) return null;
  return { code_hash: script.codeHash, hash_type: script.hashType, args: script.args };
}

const DEP_TYPE_TO_RPC = { code: "code", depGroup: "dep_group" };

// A hand-rolled converter to the exact JSON-RPC shape CKB's own
// send_transaction expects (snake_case field names) -- ccc.ccc's public
// bundle doesn't re-export its own internal JsonRpcTransformers, so this
// is a second, independent implementation of that same shape rather than
// a shared source of truth with CCC's own (equally snake_case) wire
// format.
function toRpcTransaction(tx) {
  return {
    version: numHex(tx.version),
    cell_deps: tx.cellDeps.map((d) => ({
      out_point: { tx_hash: d.outPoint.txHash, index: numHex(d.outPoint.index) },
      dep_type: DEP_TYPE_TO_RPC[d.depType],
    })),
    header_deps: tx.headerDeps,
    inputs: tx.inputs.map((i) => ({
      previous_output: { tx_hash: i.previousOutput.txHash, index: numHex(i.previousOutput.index) },
      since: numHex(i.since),
    })),
    outputs: tx.outputs.map((o) => ({
      capacity: numHex(o.capacity),
      lock: scriptToRpc(o.lock),
      type: scriptToRpc(o.type),
    })),
    outputs_data: tx.outputsData,
    witnesses: tx.witnesses,
  };
}

async function submit(tx) {
  const { tx_hash } = await postJson("/api/tx/send", { transaction: toRpcTransaction(tx) });
  return tx_hash;
}

// ---- the three flows ----

/**
 * Creates a new open escrow offer, with the OfferGuard Type Script
 * minted directly onto the same escrow cell (not as a free-standing
 * cell -- see mpesa-escrow's own check-5 doc comment for why that's
 * load-bearing). Requires a real ownership signature from the trusted
 * Verifier (Web.Ckb.Verifier, server-side) and a real signature from the
 * connected wallet on its own funding input.
 */
export async function createOffer(recipientHashHex, amountMinorUnits) {
  const { signer, config } = await getSigner();
  const addressObj = await signer.getAddressObjSecp256k1();
  const sellerLock = addressObj.script;

  const { signature: ownershipSignature, verifier_address } = await postJson(
    "/api/verifier/ownership_signature",
    { recipient_hash: recipientHashHex },
  );

  const guardArgs = concatHex(verifier_address, recipientHashHex);
  const guardScript = scriptFrom(config.offer_guard.code_hash, config.offer_guard.hash_type, guardArgs);

  const escrowArgs = concatHex(
    verifier_address,
    recipientHashHex,
    amountToLeHex8(amountMinorUnits),
    config.claims_registry.type_hash,
    guardScript.hash(),
  );
  const escrowLock = scriptFrom(config.mpesa_escrow.code_hash, config.mpesa_escrow.hash_type, escrowArgs);

  // Output order [change, escrow]: the escrow's own output index must
  // NOT be 0, so OfferGuard's ownership witness (read positionally from
  // its own output index) doesn't collide with the funding input's own
  // sighash witness, also read from index 0 -- same reasoning as
  // devnet-ops/src/create_offer.rs. `completeFeeChangeToOutput(.., 0, ..)`
  // tops up output 0 in place, rather than appending a new change output
  // at the end the way completeFeeBy would (which would push escrow to
  // index 0 instead).
  //
  // The ownership witness is set only AFTER input completion, not before:
  // `Transaction.addInput` (called internally while collecting funding
  // cells) splices in a placeholder witness whenever `witnesses.length >
  // inputs.length` at that moment -- discovered by tracing a real,
  // otherwise-inexplicable ERROR_OWNERSHIP_WITNESS_MISSING failure back
  // to this. Setting it early would get silently shifted to the wrong
  // index by that splice.
  // The escrow output needs headroom BEYOND its own empty-data minimum:
  // RESERVE later has to write 32 bytes of reservation data into this
  // SAME cell, and CKB cells can never shrink below their own occupied
  // capacity -- without this, RESERVE would need MORE capacity than the
  // cell actually holds and fail with a capacity overflow (caught via a
  // real reserveOffer failure, not anticipated up front).
  const escrowCellForSizing = ccc.CellOutput.from({ lock: escrowLock, type: guardScript });
  const escrowMinCapacity = BigInt(escrowCellForSizing.occupiedSize) * 100_000_000n; // occupiedSize is in bytes, capacity in shannon
  const escrowHeadroom = 1_000n * 100_000_000n; // 1000 CKB, matching devnet-ops's own convention
  const escrowCapacity = escrowMinCapacity + escrowHeadroom;

  const tx = ccc.Transaction.from({
    outputs: [
      { capacity: 0, lock: sellerLock },
      { capacity: escrowCapacity, lock: escrowLock, type: guardScript },
    ],
    outputsData: ["0x", "0x"],
  });

  await tx.completeFeeChangeToOutput(signer, 0, FEE_RATE);
  tx.setWitnessArgs(1, { lock: ownershipSignature });
  tx.addCellDeps(sighashCellDep(config), contractCellDep(config.mpesa_escrow), contractCellDep(config.offer_guard));

  const signed = await signer.signOnlyTransaction(tx);
  return submit(signed);
}

/**
 * Reserves an open offer for the connected wallet. Deliberately
 * unauthorized -- mpesa-escrow's own RESERVE branch reads no witness at
 * all -- so this needs no signature, only the wallet's own lock hash.
 */
export async function reserveOffer(offer) {
  const { config } = await getSigner();
  const walletHash = (await walletInfo()).lockHash;

  const escrowLock = scriptFrom(config.mpesa_escrow.code_hash, config.mpesa_escrow.hash_type, escrowArgsFromOffer(offer));
  const guardScript = scriptFrom(config.offer_guard.code_hash, config.offer_guard.hash_type, guardArgsFromOffer(offer));

  // RESERVE needs its own small fee (borrowed from the escrow cell's own
  // headroom, added at create_offer time) -- capacity-in must exceed
  // capacity-out by at least the pool's min fee rate, even for a
  // transaction that otherwise moves no value (same reasoning as
  // devnet-ops/src/claim_offer.rs's own reserve_fee).
  const reserveFee = 1_000_000n; // 0.01 CKB, comfortably over the pool minimum
  const reservedCapacity = BigInt(offer.capacity_shannon) - reserveFee;

  const tx = ccc.Transaction.from({
    inputs: [{ previousOutput: outPointFrom(offer.out_point) }],
    outputs: [{ capacity: reservedCapacity, lock: escrowLock, type: guardScript }],
    outputsData: [walletHash],
    witnesses: ["0x"],
  });
  tx.addCellDeps(contractCellDep(config.mpesa_escrow), contractCellDep(config.offer_guard));

  return submit(tx);
}

/**
 * Claims a reserved offer: the connected wallet must be the one that
 * reserved it. Needs a real claim signature from the trusted Verifier
 * (standing in for a genuine TLSNotary proof -- see Web.Ckb.Verifier's
 * own moduledoc) and a real signature from the wallet's own funding
 * input; the registry input (always-success locked) needs no signature
 * at all.
 */
export async function claimOffer(offer, txIdSeed) {
  const { signer, config } = await getSigner();

  const { tx_id_hash, signature: claimSignature } = await postJson("/api/verifier/claim_signature", {
    tx_id_seed: txIdSeed,
    recipient_hash: offer.recipient_hash,
    amount: offer.amount,
  });

  const registryCell = await getJson("/api/registry");

  const guardScript = scriptFrom(config.offer_guard.code_hash, config.offer_guard.hash_type, guardArgsFromOffer(offer));
  const registryType = scriptFrom(config.claims_registry.code_hash, config.claims_registry.hash_type, config.claims_registry.type_args);
  const alwaysSuccessLock = scriptFrom(config.always_success.code_hash, config.always_success.hash_type, "0x");

  const addressObj = await signer.getAddressObjSecp256k1();
  const buyerLock = addressObj.script;

  const claimWitnessLock = concatHex(tx_id_hash, offer.recipient_hash, amountToLeHex8(offer.amount), claimSignature);
  // Transaction.from's `witnesses` field expects ALREADY-molecule-encoded
  // witness slot bytes -- passing the raw 137-byte claim data directly
  // (instead of wrapping it in a WitnessArgs table first, `.lock` field
  // set to it) is what mpesa-escrow's own `load_witness_args` failed to
  // parse as ERROR_WITNESS_MISSING, found via a real claim failure.
  const claimWitness = ccc.hexFrom(ccc.WitnessArgs.from({ lock: claimWitnessLock }).toBytes());
  const newRegistryData = concatHex(registryCell.data, tx_id_hash);

  // input 0: the reserved escrow cell -- its own witness (index 0) is the
  // claim, set upfront and never touched by fee/input completion below
  // (nothing after this adds an input at position 0 or earlier).
  const tx = ccc.Transaction.from({
    inputs: [{ previousOutput: outPointFrom(offer.out_point) }],
    outputs: [{ capacity: offer.capacity_shannon, lock: buyerLock }],
    outputsData: ["0x"],
    witnesses: [claimWitness],
  });

  // input 1: the buyer's own funding cell -- added and signed via
  // completion below. A capacityTweak forces at least one buyer cell to
  // be pulled in even though escrow capacity already covers the payout
  // 1:1 (the buyer's presence here, not its capacity, is what
  // mpesa-escrow's own reservation check actually needs).
  //
  // Every OTHER custom witness (the registry's own empty one) is set
  // only at the very end, after all input-adding is done:
  // `Transaction.addInput` splices in a placeholder witness whenever
  // `witnesses.length > inputs.length` at the moment it's called --
  // discovered by tracing a real, otherwise-inexplicable
  // ERROR_OWNERSHIP_WITNESS_MISSING failure in createOffer back to this.
  // Setting an index-specific witness before all inputs exist risks that
  // same silent reshuffling here too.
  await tx.completeInputsByCapacity(signer, 100_000_000n);

  // output 1: the buyer's own change, pre-added as a placeholder so
  // completeFeeChangeToOutput tops it up in place.
  tx.addOutput({ capacity: 0, lock: buyerLock }, "0x");

  // input 2 / output 2: the registry -- capacity is already fixed here,
  // no change needed for it specifically.
  tx.addInput({ previousOutput: outPointFrom(registryCell.out_point) });
  tx.addOutput({ capacity: registryCell.capacity, lock: alwaysSuccessLock, type: registryType }, newRegistryData);

  await tx.completeFeeChangeToOutput(signer, 1, FEE_RATE);
  tx.setWitness(2, "0x");

  tx.addCellDeps(
    sighashCellDep(config),
    contractCellDep(config.mpesa_escrow),
    contractCellDep(config.claims_registry),
    contractCellDep(config.offer_guard),
    contractCellDep(config.always_success),
  );

  const signed = await signer.signOnlyTransaction(tx);
  return submit(signed);
}
