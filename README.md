# Bitshada: M-Pesa ↔ CKB P2P escrow

Bitshada lets someone in Kenya buy CKB with M-Pesa from another person without a custodian. A
seller locks CKB in an escrow cell on CKB, the buyer pays the seller over M-Pesa as usual, and
the buyer then claims the CKB. The goal is that the claim is released by a **zkTLS payment proof**
— a TLSNotary (MPC-TLS) proof, made on the buyer's own phone from their Safaricom account
session, that the payment happened — instead of a screenshot or a seller pressing "release".

That last step is **not live yet**: Safaricom rejects proofs for a reason outside this project's
control (see [Payment proofs: where this stands](#payment-proofs-where-this-stands)). Until it
works, the contract requires the **seller to confirm receipt** before a claim can succeed.

This mirrors [Peer](https://docs.peer.xyz) (formerly ZKP2P), which does the same for
Venmo/Revolut/Wise on Ethereum. Built during the CKBuilder track, aimed at the
[CKB Eco Fund Spark Program](https://talk.nervos.org/t/ckb-eco-fund-spark-program-mini-grant-initiative/8752).

**Status:** CKB testnet only, not audited. Try it at **https://api.bitshada.com/** (web) or
install the Android app from **https://api.bitshada.com/downloads/bitshada.apk**. The web app
has a testnet faucet.

## How it works

1. **List.** The seller creates an offer: CKB locked in an escrow cell whose lock args fix a hash
   of the seller's M-Pesa number, the exact KES price, and the Verifier's address. The offer cell
   carries an `offer-guard` type script, which only lets it be minted with a Verifier signature
   over that number hash (meant to prove the seller controls the number).
2. **Reserve.** A buyer reserves the offer for 20 minutes. Anyone can reopen it after the window
   expires. Ghosting a reservation costs time, never money: the CKB never leaves escrow.
3. **Pay.** The buyer sends the KES amount to the seller over M-Pesa, off-chain.
4. **Confirm (temporary).** The seller confirms they received the money. Claims only work on a
   confirmed reservation.
5. **Claim.** The buyer submits a Verifier-signed claim (`tx_id_hash`, recipient hash, amount).
   The lock checks the signature on-chain, checks that the claimant is the party that reserved
   the offer, and requires the M-Pesa transaction-ID hash to be appended to the `claims-registry`
   cell in the same transaction, so one payment can't be claimed twice.
6. **Reclaim.** If nobody claims before the offer's deadline, the seller takes the CKB back.

## Trust model, stated plainly

- **The Verifier.** The escrow and offer-guard scripts trust one Verifier key (mine), embedded in
  their args. The design is that the Verifier co-runs the TLSNotary MPC-TLS session, checks the
  presentation off-chain, and signs a short claim (secp256k1 + Keccak-256, TLSNotary's
  SECP256K1ETH scheme). Verifying the full TLSNotary presentation inside CKB-VM is out of scope
  for now.
- **Today the Verifier is a stand-in.** Because live proofs are blocked, `/api/verifier/*` signs
  whatever it is asked to. The on-chain checks are real, but the off-chain check they rely on
  is not in place yet. In practice:
  - the **seller-confirm** step is what stops a false claim, and
  - nothing yet stops an offer listing an M-Pesa number the seller doesn't control.
- **Seller confirm** has the same weakness as Binance P2P: a seller can withhold confirmation.
  Real proofs are meant to remove this step.

## Payment proofs: where this stands

The proof source is `myaccount.safaricom.co.ke`, Safaricom's consumer web portal. Its GraphQL
query `GetRecentMpesaTransactions` returns M-Pesa transaction ID, date, counterparty and amount.

- **Reclaim Protocol: dropped.** I built and published a Reclaim provider for that query.
  Safaricom rejected it with `"The ip used for this request is not similar to the one used to
  request this token"`: the session token is tied to the IP that logged in, and Reclaim's
  attestor always connects from its own servers.
- **TLSNotary MPC-TLS: works, but Safaricom still rejects it.** In MPC-TLS mode the prover's
  own device opens the TLS connection (TLSNotary's newer Proxy mode has the same IP problem as
  Reclaim, so it's ruled out). I cross-compiled the `tlsn` prover for `aarch64-linux-android` and
  ran it on a phone against the real endpoint, using a live session token from that phone's own
  browser. The MPC-TLS session worked — 200 OK and a verified transcript — but Safaricom's
  application layer returned the same IP-mismatch error, three times out of three, even though
  the phone's public IP matched the `clientIp` inside the token. My best explanation is that
  Safaricom routes traffic to its own sites differently inside its network. That isn't something
  app code can fix, so it's documented here as a limitation rather than worked around.

The escrow, nullifier registry and Verifier-signed claim lock don't depend on where the proof
comes from, so they work unchanged once a proof source that passes is found.

## Contracts

All in `contract/contracts/`, Rust on `ckb-std`, scaffolded with `ckb-script-templates`.

| Script | Kind | What it enforces |
|---|---|---|
| `mpesa-escrow` | Lock | Reserve / clear / confirm / claim / reclaim state machine; Verifier-signed claim; claimant must be the reserver; reserve and clear can't shrink the cell or change its type |
| `offer-guard` | Type | An offer can only be minted with a Verifier signature over the seller's number hash (a lock script never runs at mint time, so this has to be a type script) |
| `claims-registry` | Type (Type ID) | One live cell holding an append-only list of claimed M-Pesa transaction-ID hashes; rejects duplicates |
| `always-success` | Lock | Test/devnet helper only |

`cd contract && make build && make test` builds the scripts and runs 40 tests in `ckb-testtool`
(including negative tests for each rejection code).

## Repo layout

- **`contract/`** — the CKB scripts above and their tests.
- **`web/`** — Phoenix LiveView app: offer list/create/reserve/confirm/claim, CCC wallet connect,
  a self-serve testnet faucet, a feedback form, and the JSON API the mobile app uses.
  `cd web && mix phx.server` (set `CKB_NETWORK=testnet` to use the testnet deployment).
- **`mobile/`** — Flutter Android app over the same JSON API. `cd mobile && flutter run`.
- **`devnet-ops/`** — Rust CLI tools that deploy the scripts and drive offers end to end against
  a local devnet or testnet (`CKB_RPC_URL`, `CKB_DATA_DIR`, `CKB_KEY_FILE`).
- **`devnet/`** — local CKB devnet config.
- **`docs/`** — build plan.

## Testnet deployment (Pudge)

| Script | `code_hash` (`data1`) | Deploy tx |
|---|---|---|
| `mpesa-escrow` (v2, seller confirm) | `0x0389a5f0b48e27d5c1b12ca700440c0b2eff2d94c4e8f824ed55cb4e9a3b09ae` | [`0x3fa7b70b…`](https://testnet.explorer.nervos.org/transaction/0x3fa7b70b7dd6b77f836d851cee3b82464ca662702cc28548695849d99837ec9a) |
| `offer-guard` | `0x13c3c2b25bda33139e4d0ba52868b478d98d47c166d979e18898a3b8cfa786ba` | [`0xa5a85f5c…`](https://testnet.explorer.nervos.org/transaction/0xa5a85f5cc3a1977d8e244e01681312a7c62d7a9b4c09eafa8d207a81a75083c2) |
| `claims-registry` | `0x5cfd31a4a0775052dd45b85637cabd9086b5f7f5d257227153b583d72f3c1000` | [`0xa5a85f5c…`](https://testnet.explorer.nervos.org/transaction/0xa5a85f5cc3a1977d8e244e01681312a7c62d7a9b4c09eafa8d207a81a75083c2) |

## Roadmap

- A payment-proof source Safaricom accepts, then remove the seller-confirm step
- Less trust in the single Verifier key (m-of-n verifiers, a TEE-hosted verifier, or partial
  on-chain checks)
- The reverse direction (CKB → KES): the same proof with the roles swapped
- A small pilot with the CKBuilder cohort
