// Translates the raw errors createOffer/reserveOffer/claimOffer can
// throw (CCC-level pre-flight errors, CKB pool-rejection JSON, on-chain
// script ValidationFailures) into plain language for the UI. Contract
// error tables mirrored here from each contract's own `main.rs` --
// duplicated, not imported, same reasoning as ckb.js's own byte-layout
// comment: this is a second, independent read of the same wire format.

const CONTRACT_ERRORS = {
  // mpesa-escrow (contract/contracts/mpesa-escrow/src/main.rs)
  "0x74e8b52b2043efe2386a5f838a0a0ce44d0d087025e95a575eb40ba38b54e0f9": {
    4: "This offer's on-chain data is malformed.",
    5: "The claim is missing its signature.",
    6: "The claim signature is the wrong length.",
    7: "The claim signature is malformed.",
    8: "Could not recover a signer from the claim signature.",
    9: "The claim wasn't signed by the trusted verifier.",
    10: "The claim's recipient doesn't match this offer.",
    11: "The claim's amount doesn't match this offer.",
    12: "This offer's payment registry no longer exists, so it can never be claimed (a leftover test offer -- it should no longer appear in the list; try refreshing).",
    13: "The registry update in this transaction doesn't match the claim.",
    14: "This offer is missing its reservation data.",
    15: "Unsupported transaction shape for this offer.",
    16: "This offer was reserved by a different wallet.",
    17: "This offer is missing its ownership badge.",
  },
  // offer-guard (contract/contracts/offer-guard/src/main.rs)
  "0x13c3c2b25bda33139e4d0ba52868b478d98d47c166d979e18898a3b8cfa786ba": {
    4: "This offer's ownership badge is malformed.",
    5: "Unsupported transaction shape for the ownership badge.",
    6: "Missing the seller's ownership signature.",
    7: "The ownership signature is the wrong length.",
    8: "The ownership signature is malformed.",
    9: "Could not recover a signer from the ownership signature.",
    10: "The ownership signature wasn't from the trusted verifier.",
  },
  // claims-registry (contract/contracts/claims-registry/src/main.rs)
  "0x5cfd31a4a0775052dd45b85637cabd9086b5f7f5d257227153b583d72f3c1000": {
    4: "Registry identity check failed.",
    5: "The registry can only be created empty.",
    6: "The registry update must add exactly one claim record.",
    7: "The registry's existing history was unexpectedly altered.",
    8: "This payment has already been claimed elsewhere.",
    9: "Unsupported transaction shape for the registry.",
  },
};

function tryScriptError(message) {
  const codeMatch = message.match(/error code (\d+)/);
  const hashMatch = message.match(/by-data-hash\/(0x)?([0-9a-fA-F]+)\.html/);
  if (!codeMatch || !hashMatch) return null;
  const code = Number(codeMatch[1]);
  const codeHash = "0x" + hashMatch[2].toLowerCase();
  return CONTRACT_ERRORS[codeHash]?.[code] ?? null;
}

const KNOWN_PATTERNS = [
  [/insufficient ckb, need ([\d.]+) extra ckb/i, (m) => `You need about ${Number(m[1]).toFixed(2)} more CKB in your wallet for this.`],
  [/InsufficientCellCapacity/, () => "One of this transaction's cells doesn't have enough CKB capacity -- try funding your wallet with more CKB."],
  [/Malformed.*Overflow.*outputs capacity.*inputs capacity/, () => "This offer doesn't have enough spare capacity for this action (likely an old test offer) -- try a different one or refresh."],
  [/PoolRejectedTransactionByMinFeeRate|LowFeeRate/, () => "The network rejected this for too low a fee -- please try again."],
  [/Dead\(OutPoint/, () => "That cell was already spent by another transaction -- refresh and try again."],
  [/Unknown\(?OutPoint|Resolve Unknown OutPoint/, () => "That offer no longer exists on chain -- refresh the page."],
];

/** Best-effort plain-language rendering of a raw error/Error-string from ckb.js. */
export function friendlyError(raw) {
  const message = String(raw);

  const scriptMsg = tryScriptError(message);
  if (scriptMsg) return scriptMsg;

  for (const [pattern, render] of KNOWN_PATTERNS) {
    const m = message.match(pattern);
    if (m) return render(m);
  }

  return message.replace(/^Error:\s*/, "");
}
