// Throwaway: test claimOffer alone against an already-reserved offer, to
// avoid needing a full create+reserve cycle (and its funding) each retry.
const realFetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  if (typeof input === "string" && input.startsWith("/")) input = "http://localhost:4000" + input;
  return realFetch(input, init);
};
globalThis.__CKB_DEBUG__ = true;
const { claimOffer } = await import("./ckb.js");

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

const { offers } = await (await fetch("http://localhost:4000/api/offers")).json();
const offer = offers.find((o) => o.out_point.tx_hash === process.argv[2]);
if (!offer) throw new Error("offer not found");
console.log("offer:", offer);

const claimTx = await claimOffer(offer, `claim-only-verify-${Date.now()}`);
console.log("tx:", claimTx);
await waitCommitted(claimTx);
console.log("committed!");
