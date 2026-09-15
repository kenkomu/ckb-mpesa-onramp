// Throwaway verification script -- NOT part of the shipped app. Runs the
// actual ckb.js module (unmodified) from Node against the real running
// Phoenix server + devnet, to get genuine end-to-end proof the browser
// transaction-building code works, rather than shipping it untested.
// Run with: node --localstorage-file=/tmp/verify_ls.json assets/js/verify_flows.mjs

// Node has no page origin for ckb.js's relative fetch("/api/...") calls
// (the browser resolves those against the page's own URL automatically)
// -- prefix them here rather than changing the shipped module for a
// test-only concern.
const realFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  if (typeof input === "string" && input.startsWith("/")) {
    input = "http://localhost:4000" + input;
  }
  return realFetch(input, init);
};

globalThis.__CKB_DEBUG__ = true;
const { createOffer, reserveOffer, claimOffer, walletInfo } = await import("./ckb.js");

async function waitCommitted(txHash) {
  for (let i = 0; i < 60; i++) {
    const res = await fetch("http://127.0.0.1:8114", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: 1, jsonrpc: "2.0", method: "get_transaction", params: [txHash] }),
    });
    const { result } = await res.json();
    if (result?.tx_status?.status === "committed") return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`${txHash} not committed within 30s`);
}

async function main() {
  const info = await walletInfo();
  console.log("wallet:", info);

  const recipientHash = "0x" + "07".repeat(32); // same stand-in recipient the devnet-ops scripts used
  const amount = 25000;

  console.log("\n=== createOffer ===");
  const createTx = await createOffer(recipientHash, amount);
  console.log("tx:", createTx);
  await waitCommitted(createTx);
  console.log("committed.");

  // Find the offer we just created via the real offers API.
  const { offers } = await (await fetch("http://localhost:4000/api/offers")).json();
  const offer = offers.find((o) => o.out_point.tx_hash === createTx);
  if (!offer) throw new Error("newly created offer not found in /api/offers");
  console.log("offer:", offer);

  console.log("\n=== reserveOffer ===");
  const reserveTx = await reserveOffer(offer);
  console.log("tx:", reserveTx);
  await waitCommitted(reserveTx);
  console.log("committed.");

  // Refetch from the real API rather than hand-building the post-reserve
  // state: capacity_shannon shrank by the RESERVE fee, and the real UI's
  // own offer list would naturally reflect that on next load too.
  const { offers: offersAfterReserve } = await (await fetch("http://localhost:4000/api/offers")).json();
  const reservedOffer = offersAfterReserve.find((o) => o.out_point.tx_hash === reserveTx);
  if (!reservedOffer) throw new Error("reserved offer not found in /api/offers");
  console.log("reservedOffer:", reservedOffer);

  console.log("\n=== claimOffer ===");
  const claimTx = await claimOffer(reservedOffer, `node-verify-${Date.now()}`);
  console.log("tx:", claimTx);
  await waitCommitted(claimTx);
  console.log("committed. Full create -> reserve -> claim flow verified via the REAL browser-shaped JS code.");
}

main().catch((err) => {
  console.error("FAILED:", err);
  process.exit(1);
});
