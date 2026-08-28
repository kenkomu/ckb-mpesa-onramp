# CKB ↔ M-Pesa Trustless Onramp

A trustless M-Pesa↔CKB onramp using zkTLS. A buyer proves — cryptographically, straight from
their own Safaricom Selfcare web session — that they paid a seller via M-Pesa, and a CKB smart
contract releases escrowed funds automatically. No custodian, no bridge operator to trust.

This mirrors [Peer](https://docs.peer.xyz) (formerly ZKP2P), live on Ethereum for
Venmo/Revolut/PayPal/Cash App/Zelle/Wise, but is a first for CKB and for African mobile money.

Built for the [CKB Eco Fund Spark Program](https://talk.nervos.org/t/ckb-eco-fund-spark-program-mini-grant-initiative/8752)
mini-grant.

## How it works

1. A seller locks CKB in an on-chain escrow cell, committing to a hashed M-Pesa number, a price
   in KES, and a deadline — proving beforehand (via a [Reclaim Protocol](https://reclaimprotocol.org)
   proof) that they actually control that M-Pesa number.
2. A buyer reserves the offer, pays the seller the KES amount directly via M-Pesa — normal,
   off-chain, exactly like the informal P2P trading that already happens today.
3. The buyer proves the payment by generating a Reclaim proof against their own Safaricom
   Selfcare transaction history — a live cryptographic proof, not a screenshot or a claim.
4. The CKB contract verifies the proof and releases the escrowed CKB straight to the buyer's
   wallet, typically within seconds. No support ticket, no manual dispute process.

## Repo layout

- **`contract/`** — the CKB Lock Script (Rust, `ckb-script-templates`). `cd contract && make test`.
- **`web/`** — the Phoenix/LiveView web app: offer creation/browsing, CCC wallet connect, the
  Reclaim proof flow, and the JSON API the mobile app consumes. `cd web && mix phx.server`.
- **`mobile/`** — the Flutter mobile app, a thin client over `web/`'s JSON API. `cd mobile && flutter run`.
- **`docs/`** — grant writeup, demo notes, funding-usage breakdown.

## Status

Early development. See `docs/` for the current build plan and progress.
