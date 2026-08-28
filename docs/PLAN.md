# M-Pesa↔CKB Trustless Onramp — MVP Build Plan

## Context

Ken is applying to CKB's Spark Program mini-grant ($1,000–$2,000, 1–2 month timeline, decided in ~1 week). After several research passes, the strongest idea to emerge is a **trustless M-Pesa↔CKB onramp using zkTLS**: a buyer proves — cryptographically, straight from their own bank/telco web session — that they paid a seller via M-Pesa, and a CKB smart contract releases escrowed funds automatically. No custodian, no bridge operator to trust. This mirrors ZKP2P — now rebranded **Peer** (`docs.peer.xyz`), live on Ethereum for Venmo/Revolut/PayPal/Cash App/Zelle/Wise via a browser-extension-based zkTLS proof (confirmed: escrow contract + buyer-side proof extension + automatic release on verified proof, matching this plan's mechanism) — but is a first for CKB and for African mobile money specifically. Worth citing Peer by its current name in the grant writeup, not the old ZKP2P branding.

The existing CKB↔M-Pesa project, **Dular**, is a wallet/UX layer with (as far as is publicly known) a trust-based ramp underneath. This project is the missing trust-minimized verification primitive — complementary to Dular, not competing with it.

**⚠️ Unverified — resolve before submitting:** a deep-research pass (general web search, Nervos Talk forum search, targeted app/wallet searches) found **no independent trace of a project called "Dular"** anywhere. It's possible this is real but simply not web-indexed (a Discord/Telegram-only project, a very early-stage effort, or a name Ken heard directly from someone in the CKB community) — but it cannot currently be cited as an established fact. **Before the grant application repeats this claim, Ken should confirm directly** (ask in the CKB Builder Track cohort or Nervos Talk, or produce the source of where "Dular" was first mentioned). If it can't be confirmed, drop the "complementary to Dular" framing entirely rather than risk citing a project that doesn't exist in a grant submission — the rest of the honest-positioning argument (the Binance comparison below) doesn't depend on Dular and stands on its own.

Ken chose **M-Pesa** as the first network over MTN MoMo, prioritizing personal access to Kenya's existing informal P2P crypto-for-M-Pesa trading community as a real test audience over MTN's broader continental reach. This plan had to close one open technical question before it could be called feasible: whether M-Pesa actually has a usable web session for zkTLS to target, since earlier research found only app/USSD access. It does — see below.

**Grant scoring reminder:** the program explicitly scores a "user testing and operational plan" alongside code, so the pilot in Phase 4 is not optional polish — it's a scored deliverable.

## Honest positioning: this is not a Binance P2P competitor

Binance P2P already does almost exactly this for KES: seller posts an ad, buyer pays via M-Pesa, Binance escrows the crypto, buyer marks "paid," the **seller manually confirms**, escrow releases. It has liquidity, a reputation system, and human dispute resolution this project cannot match in a 1–2 month MVP. Pitching this as a Binance replacement is not credible and shouldn't be the framing.

The real differentiation, and the honest pitch:
- **Binance's actual weak point is the manual confirmation step, not the escrow.** Binance already escrows the crypto — that's not the gap. The gap is that release depends on the seller manually confirming payment, which is exactly where P2P fraud lives (fake payment screenshots, disputes, chargebacks after release, social-engineered sellers). This design removes that step: release requires a live cryptographic proof from the buyer's own Safaricom session, not a claim or a screenshot. A forged "I paid" is structurally impossible, not just against policy.
- **Binance P2P doesn't meaningfully serve CKB** — its P2P liquidity is concentrated in USDT/BTC. Someone who specifically wants CKB has no clean KES on-ramp today. That's the real, narrow niche.
- **No account to freeze.** This isn't a hypothetical: in April 2026, Kenya's Directorate of Criminal Investigations directed Binance to freeze an undisclosed number of Kenyan users' accounts as part of an anti-money-laundering crackdown, locking traders out of funds held in P2P trades — with Binance declining to say why and users reporting no clear process to get funds back ([TechCabal](https://techcabal.com/2026/04/21/why-kenyan-authorities-froze-binance-user-accounts/), [Business Daily Africa](https://www.businessdailyafrica.com/bd/markets/currencies/kenya-freezes-binance-accounts-in-money-laundering-purge-5432978)). This is a concrete, dated, Kenya-specific incident to cite directly in the pitch, not a vague "documented history" — and it's exactly the choke point that doesn't exist here: there's no account to freeze because there's no account, only a Lock Script that releases against a cryptographic proof.

**Consequence for the pilot audience (Phase 4):** generic P2P traders will rationally stay on Binance for liquidity — recruiting them as the pilot group oversells what this MVP can realistically win. The more honest test audience is **the CKB community itself** — the Builder Track cohort and anyone locally who specifically wants CKB — not the broader crypto-agnostic P2P trading crowd.

## Non-payment and abuse cases

Two failure modes that need explicit handling, not just the happy path:

1. **Buyer reserves an offer and never pays (ghosting).** The offer needs a reservation mechanism: clicking "Buy" soft-locks the offer to that buyer for a short window (e.g. 20 minutes), preventing two buyers from racing to pay the same offer. If no valid proof arrives before expiry, the lock releases and the offer reopens automatically. **The seller's crypto is never at risk during this** — it stays in escrow the whole time and only ever moves against a real matching proof. The cost of ghosting is wasted time, never money. State this explicitly in the pitch as a designed safety property, not an omission.
2. **Malicious offer listing a stranger's M-Pesa number**, to trick a buyer into paying someone who never agreed to sell anything. Mitigation: the **seller** also submits a Reclaim proof at offer-creation time, proving they control the M-Pesa number they're listing — every offer is bound to a verified-owned number, not just typed in.

## The technical unlock: Safaricom Selfcare is a real, provable web session

`selfcare.safaricom.co.ke` is a genuine individual-consumer web portal — log in with Safaricom number + password, and it shows **M-Pesa transaction history with transaction ID, date, recipient name/number, amount, and running balance**, plus current M-Pesa balance. The portal's own URLs (e.g. `/frontend/rest/v1/register`) show it's a REST-API-backed web app, which is the easiest shape for a zkTLS "provider" to target (extract one JSON field — the matching transaction — rather than scraping rendered HTML).

This is the proof source for the whole system: a buyer logs into their own Safaricom Selfcare session through the Reclaim SDK, and Reclaim's provider extracts and attests to one specific transaction record without exposing the rest of the buyer's statement.

## Locked technical decisions

| Decision | Choice | Why |
|---|---|---|
| Network | M-Pesa | Ken's choice — real personal test-market access outweighs MTN MoMo's cleaner continental story |
| Proof target | `selfcare.safaricom.co.ke` transaction history | Only confirmed individual, authenticated, structured-data web session for M-Pesa |
| zkTLS layer | Reclaim Protocol SDK (not raw TLSNotary) | Ships a decentralized multi-attestor trust model already, plus production web *and* mobile SDKs — fastest path to both surfaces in a 1–2 month window |
| CKB contract base | `ckb-script-templates` (cargo-generate), **not** Capsule | Capsule is deprecated per the CKBuilder Handbook; `ckb-script-templates` is what Ken has been using since Week 7 and is confirmed working on this machine |
| Web framework | Phoenix (LiveView) | Ken's choice; Elixir/OTP already installed on this machine (`mix` on PATH). LiveView's server-push model fits a live open-offers list well, and its JS-hooks mechanism is a standard, documented way to embed the browser-only Reclaim JS SDK and CCC wallet-connect code — confirmed via Phoenix's own `js-interop` docs |
| Mobile framework | Flutter | Ken's choice; he already has a Flutter app in this workspace (`fieldlink-mobile-app-revamp`), so this is applying an existing skill, not adopting a new one |
| Repo | New, dedicated repo (not inside `CKBuilder` or `scripting-basics-labs`) | `CKBuilder` is Ken's course-journal repo (11 weekly reports + a Capsule practice contract) and `scripting-basics-labs` is untracked course lab code — a grant submission needs its own clean, verifiable GitHub repo per Spark's anti-fraud rule (verified repo required) |

## Repo layout & project initialization

Three toolchains (Rust/Cargo, Elixir/Phoenix, Dart/Flutter) need to coexist in the **one** verified repo the grant's anti-fraud rule requires. None of the three requires its config file at the literal git root — a Cargo workspace, `mix.exs`, and `pubspec.yaml` can each live in their own subdirectory — so the repo is one monorepo, three self-contained subfolders, each initialized with that ecosystem's own official tooling, nothing hand-rolled:

```
ckb-mpesa-onramp/                  (repo root: README, LICENSE, docs/)
├── contract/                      (Cargo workspace root — not repo root)
│   ├── contracts/mpesa-escrow/    (scaffolded via `make generate CRATE=mpesa-escrow`)
│   ├── tests/
│   ├── scripts/find_clang
│   ├── Makefile
│   └── rust-toolchain.toml        (pinned exact version, see Toolchain note above)
├── web/                           (Phoenix app root)
│   ├── mix.exs
│   ├── lib/
│   └── assets/                    (JS hooks: @reclaimprotocol/js-sdk, @ckb-ccc/connector)
├── mobile/                        (Flutter app root)
│   ├── pubspec.yaml
│   └── lib/
└── docs/                          (grant writeup, demo notes, funding-usage breakdown)
```

Official init commands and prerequisites, confirmed against each framework's own docs directly (not assumed):

- **`contract/`** — already established: `make generate CRATE=mpesa-escrow` run from inside `contract/`, following the exact `scripting-basics-labs` Makefile pattern (`cargo-generate` against `ckb-script-templates`).
- **`web/`** — confirmed via Phoenix's official install docs (`phoenix.hexdocs.pm/installation.html`): `mix archive.install hex phx_new`, then `mix phx.new web` run from inside the (already-created) `ckb-mpesa-onramp/` directory. Prerequisites: Elixir 1.17+ and Erlang/OTP 25+ — this machine already has Elixir 1.20.2/OTP 28, comfortably above both, so no toolchain setup needed here either. **Recommend the `--no-ecto` flag**: Phoenix's role in this architecture is an indexer/relay over CKB, not a system of record (see "What Phoenix actually is" above) — an in-memory cache (ETS/GenServer) covers the MVP's needs, and skipping Ecto means not having to stand up and operate a Postgres instance for a 1–2 month grant pilot. Linux note: `inotify-tools` is required for LiveView's dev-mode live-reload — worth confirming it's installed before Week 4, not discovering its absence mid-week.
- **`mobile/`** — confirmed via Flutter's official docs (`docs.flutter.dev/get-started/install`): `flutter create mobile` run from inside `ckb-mpesa-onramp/`. Dart ships bundled with the Flutter SDK, no separate install needed. Flutter's docs list current stable as 3.47 as of this research — record whichever exact version actually ends up installed on this machine in the new repo's docs when Week 6 starts, for the same reproducibility reason `rust-toolchain.toml` is pinned to an exact version rather than left floating.

Each subdirectory stays buildable with that ecosystem's own standard commands (`cd contract && make test`, `cd web && mix phx.server`, `cd mobile && flutter run`) — a grant reviewer cloning the repo doesn't need anything hand-rolled to get any of the three parts running.

## Architecture

```
Seller                          Buyer                         CKB L1
  |                                |                              |
  |--(0) proves control of own M-Pesa number------------------->  |
  |   via Reclaim proof against selfcare.safaricom.co.ke          |
  |   (prevents listing a stranger's number)                      |
  |                                |                              |
  |--(1) create Offer cell------------------------------------->  |
  |   locks N CKB/UDT in escrow Lock Script,                      |
  |   commits hash(seller M-Pesa number), price in KES, deadline  |
  |                                |                              |
  |                                |--(2) sees offer (web/mobile app lists open Offer cells)
  |                                |
  |                                |--(3) taps "Buy" — soft-locks the offer to this buyer
  |                                |    for a short reservation window (~20 min)
  |                                |
  |<-------(4) pays KES via M-Pesa, off-chain, informal P2P norm--|
  |                                |
  |                                |--(5) logs into selfcare.safaricom.co.ke
  |                                |    via Reclaim SDK (web or mobile app)
  |                                |
  |                                |<-(6) Reclaim attestor network co-signs
  |                                |    a claim: {recipient, amount, txId, date}
  |                                |    (buyer's session data never leaves their device
  |                                |     except the one matched transaction)
  |                                |
  |                                |--(7) submits Reclaim proof in an Unlock tx------->|
  |                                |                              |
  |                                |                    Lock Script checks:
  |                                |                    a) attestor signatures valid
  |                                |                    b) claim.recipient == seller's hash
  |                                |                    c) claim.amount == offer price
  |                                |                    d) claim.txId not used before (nullifier)
  |                                |                    e) within offer deadline
  |                                |                    f) reservation belongs to this buyer
  |                                |                              |
  |                                |<-----------(8) escrow releases to buyer-----------|
  |                                |                              |
  |<--(9) if reservation expires unpaid, offer reopens automatically------------------>|
  |<--(10) if unclaimed past deadline entirely, seller reclaims via `since` timelock-->|
```

Two off-chain apps (web + mobile), one on-chain Lock Script, one Reclaim provider config. No new proving system, no circuit-writing — this composes existing pieces. Steps 0 and 3 are new since the reservation/abuse-prevention discussion below — they add real scope, not just documentation, and are reflected in the contract design and Week 2 estimate.

## User flow

**Seller:**
1. Open the app, connect a CKB wallet (via CCC — JoyID etc.)
2. Create an Offer: amount of CKB to sell, price in KES
3. Confirm — locks the CKB into an on-chain escrow cell (seller's M-Pesa number is hashed, never shown publicly)
4. Offer appears in the app's open-offers list, waits for a buyer
5a. Bought: offer shows "Sold," funds already released — nothing further to do
5b. Unclaimed past deadline: reclaim the locked CKB with one click (timeout refund path)

**Buyer:**
1. Open the app — no signup, no KYC to the app itself, just a CKB wallet
2. Browse open offers, pick one, tap "Buy"
3. App shows the seller's M-Pesa number and the exact KES amount to send
4. Send that amount via the buyer's own M-Pesa app — normal, outside this app, exactly like the informal P2P trading that already happens today
5. Return to the app, tap "I've paid"
6. Reclaim flow triggers: buyer logs into **their own** Safaricom Selfcare account (number + password)
7. Reclaim finds the matching transaction in the buyer's own history and proves *just that one transaction* — password and every other transaction never touch the app or the blockchain
8. App submits the proof to the CKB contract
9. Contract validates it and releases the escrowed CKB straight to the buyer's wallet — typically within seconds
10. Done — no support ticket, no dispute process for the happy path, because the payment proof *is* the unlock condition

**Known edge case (flag in the pitch, don't hide it):** if a buyer pays via M-Pesa but doesn't complete steps 6–9 before the seller's deadline, the seller could reclaim the escrow via timeout while the buyer has already paid — a griefing risk. MVP mitigation: a generous claim window (30–60 minutes) and clear in-app messaging to claim immediately after paying. ZKP2P has this same structural limitation; it's not unique to this design.

## CKB contract design

New crate, e.g. `contracts/mpesa-escrow/src/main.rs`, scaffolded via `make generate CRATE=mpesa-escrow` (confirmed working: `Makefile` in `scripting-basics-labs` runs `cargo generate --git https://github.com/cryptape/ckb-script-templates contract --destination contracts --name $(CRATE)`).

Escrow **Lock Script** logic, in order:
1. **Nullifier / replay protection** — reuse the cell-uniqueness pattern from `contracts/typeid/src/main.rs` in `scripting-basics-labs` (`ckb_std::type_id::check_type_id(0, 32)`), adapted so the "unique thing" is the Reclaim claim's `txId` rather than a mint event — prevents the same M-Pesa payment from unlocking more than one offer.
2. **Attestor signature verification** — **corrected after reading Reclaim's actual on-chain reference implementation** (`Reclaim.sol`, the official Solidity verifier): attestors don't sign with a plain pubkey-verify scheme — they produce Ethereum-style **recoverable** ECDSA/secp256k1 signatures, and the reference verifier calls `ecrecover`-equivalent signature *recovery* to get a signer, then checks that against a witness list identified by **Ethereum address** (`keccak256(pubkey)`, last 20 bytes) — not a raw public key. The CKB contract needs to replicate this exactly, against a small hardcoded set of Reclaim attestor addresses (MVP simplification; document as a trust assumption, not hidden): recover the signer from `(signature, message hash)`, Keccak256-hash the recovered pubkey, compare the last 20 bytes to the known attestor address list. Two crates cover this in pure-Rust `no_std`, both from the RustCrypto family so they're built to interoperate: `k256` (v0.12+, with its `ecdsa`/recovery feature — `VerifyingKey::recover_from_*`, confirmed to support recoverable Ethereum-style signatures) for the ECDSA recovery step, and `sha3` (RustCrypto's Keccak256/SHA-3 implementation) for the address derivation — CKB's native hash is Blake2b, so Keccak256 has to come from an external crate regardless of which ECDSA library is used. RISC-V buildability for both is still to be confirmed hands-on in Week 2 (see named risk below), but there's now a specific, correct crate pairing to test rather than a guess.
3. **Claim-field matching** — decode the claim payload (JSON or a fixed binary encoding chosen at build time) and check `recipient == hash(seller_mpesa_number)` and `amount == offer_price`.
4. **Reservation check** — the Offer cell's data carries an optional `(reserved_by: pubkey_hash, reserved_until: timestamp)` pair, set when a buyer taps "Buy" (a small on-chain update transaction, not just an off-chain UI state, so a second buyer's proof genuinely cannot race the first). The unlock transaction is only valid if `reserved_by` matches the proof submitter and `now <= reserved_until`; past `reserved_until` with no valid proof, anyone can submit a "clear reservation" transaction reopening the offer.
5. **Seller-ownership check at offer creation** — a separate, smaller validation (could live in the same Lock Script or a lightweight Type Script on the Offer cell) that only allows creating an Offer cell if it's accompanied by a Reclaim proof of the seller controlling `seller_mpesa_number` — same attestor-signature-verification code as the buyer path, reused, not rebuilt.
6. **Deadline check** — CKB's `since` field for the overall offer timeout/refund path back to the seller.

Point 4 and 5 are the direct result of the ghosting/abuse discussion above — they add real scope over the original single-buyer-single-check design and are reflected in the Week 2 estimate below.

Test shape: follow the existing pattern in `tests/src/tests.rs` (`Context::default()` → deploy lock/type scripts → build a transaction with the escrow cell as input, a Reclaim-proof witness → `context.verify_tx()`), but in the **new repo's own test file**, not appended to the course's 1988-line shared file.

**Toolchain note:** `scripting-basics-labs/rust-toolchain.toml` pins floating `channel = "stable"` (currently resolves to 1.97.1), not an exact version. For a grant submission a reviewer needs to build reproducibly — pin an exact version (e.g. `channel = "1.97.1"`) in the new repo's `rust-toolchain.toml`. `clang-19`, `llvm-19`, and the `riscv64imac-unknown-none-elf` target are all already installed on this machine, so no new toolchain setup is needed.

## Off-chain app design

**Stack choice:** Phoenix (LiveView) for web, Flutter for mobile — both Ken's picks. Both are pieces of tooling he already has real experience with (Elixir/`mix` already installed on this machine; an existing Flutter app already in this workspace, `fieldlink-mobile-app-revamp`), so this is not a fresh-learning-curve risk like it would be for someone adopting either framework cold.

- **Reclaim provider**: build a custom provider against `selfcare.safaricom.co.ke` via Reclaim's Dev Tool (no African-mobile-money provider was found pre-built in Reclaim's catalog — this needs to be built, not assumed). Provider config: URL pattern for the transaction-history endpoint, JSONPath/XPath to extract `recipient`, `amount`, `txId`, `date` for one matched transaction.

- **How the Reclaim proof flow actually works (matters for the mobile decision below):** the SDK generates a `requestUrl` + a `statusUrl`. The `requestUrl` is what the user acts on — opened directly if the official Reclaim mobile app or browser extension is present, or shown as a QR code otherwise — and that's where the actual zkTLS session against `selfcare.safaricom.co.ke` happens, inside **Reclaim's own app**, not inside anything Ken builds. The caller just polls (or gets a callback on) `statusUrl` until the proof is ready. So the integration surface on any platform is small: generate a request, present a URL/QR, poll for a result — a thin HTTP flow, not a heavy platform SDK.

- **Web app (Phoenix)**: `@reclaimprotocol/js-sdk` (npm, v5.2.0 confirmed current) invoked from a Phoenix LiveView JS hook (`phx-hook`) — this is Phoenix's standard, documented mechanism for running browser-only JS (confirmed against LiveView's own `js-interop` docs) inside a server-rendered page, so the SDK still executes entirely client-side. Same JS hook pattern is used for the CCC wallet connector (`@ckb-ccc/connector`, the actual npm package — confirmed current, supports JoyID/OKX/UniSat/MetaMask). Flow: connect CCC wallet → list open Offer cells (server-rendered via LiveView, backed by Phoenix's own CKB indexer, see below) → create/accept an offer → trigger Reclaim proof flow → submit unlock transaction. Phoenix also exposes a **JSON API** alongside the LiveView pages — this is what the Flutter app consumes for all non-signing data (offer listing, offer detail, submitting a completed proof/transaction for relay).

- **What Phoenix actually is in this architecture — an indexer + relay, not a custodian.** It mirrors CKB Offer-cell state into a queryable API (polling a CKB RPC node — no separate indexer infra needed at MVP scale) and can relay an already-signed transaction to the network as a convenience. It never holds a private key and never signs anything. This matters for the pitch: if Phoenix is down, the worst case is a degraded UI (can't browse offers through the app), not a fund-safety issue — that guarantee still comes only from the Lock Script. Document this distinction explicitly in the grant writeup, since "there's now a backend server" invites an obvious "wait, is this still trustless?" question from a reviewer.

- **Mobile app (Flutter) — Reclaim side**: the official `reclaim_sdk` Flutter package exists on pub.dev but **its GitHub repo is archived (confirmed, archived and now read-only) — do not build on it.** Given the request/poll shape described above, the fix is straightforward: skip the package and call Reclaim's `requestUrl`/`statusUrl` HTTP flow directly from Dart (plain `http` package calls), present the request as a QR code or an "Open Reclaim app" deep link, and poll `statusUrl`. This is genuinely less risky than depending on an abandoned wrapper, and it's the same underlying flow the web app uses — one proof mechanism, two thin front-ends over it.

- **Mobile app (Flutter) — CKB wallet-connect side**: there is no mature native Dart/Flutter SDK for JoyID or CCC. JoyID's own docs list a "Native App" page under Applications for exactly this, but as of this research it's still a stub (page exists, content says under construction) — this isn't unique to Flutter, the same gap would have existed under the original React Native plan too, since JoyID's SDK is JS-only there as well; switching to Flutter just makes the gap explicit instead of silently assuming React Native would have solved it. Mitigation: reuse the exact same "hop out to a URL, come back via deep link" shape as the Reclaim flow above — the Flutter app opens a small Phoenix-hosted page (system browser, not an embedded WebView) that runs the existing `@ckb-ccc/connector` JS flow to connect the wallet and sign the one specific transaction, then deep-links back into the app with the signed tx. One consistent integration pattern covers both external dependencies instead of two different ones (no WebView plugin, no JS-bridge code to maintain).

- **Build mobile second, after the web app + contract are proven end-to-end** — still the first thing cut if the timeline slips (see Risks & cut list), since both of the pieces above are genuinely new integration surface on top of what the web app already has to build anyway.

## Week-by-week plan (targeting the low end of 1–2 months = ~6 weeks, leaving buffer)

**Week 1 — De-risk the riskiest assumption first.** Build the custom Reclaim provider against `selfcare.safaricom.co.ke` and get one real, end-to-end Reclaim proof of a real M-Pesa transaction. Do this *before* writing any CKB code — if this doesn't work cleanly, the whole plan needs rethinking, and it's cheaper to find that out in week 1 than week 5.
*Verification: a real Reclaim proof object, generated against Ken's own M-Pesa account, that independently verifies against Reclaim's attestor signatures.*

**Week 2 — CKB escrow contract.** Scaffold `mpesa-escrow` in the new repo, implement the six Lock Script checks above (nullifier, attestor signature, claim matching, reservation, seller-ownership, deadline) using a **mocked** proof payload shaped like Week 1's real output. Full test coverage in the new repo's `tests/src/tests.rs`, following the existing `scripting-basics-labs` test pattern. This grew from four checks to six after working through the ghosting and fake-offer abuse cases — budget accordingly, this is now the single largest week.
*Verification: `cargo test -p tests` passing, covering the happy path, a forged-signature rejection, a replayed-txId rejection, a second-buyer-races-the-reservation rejection, an unverified-seller-number rejection, and a timeout-refund path.*

**Week 3 — Wire real proofs to the real contract.** Feed Week 1's actual Reclaim proof output into Week 2's contract logic (still on a local devnet, per the `ckb run -C devnet` / `ckb miner -C devnet` pattern already used in `scripting-basics-labs`). Fix whatever the real data format reveals that the mock missed.
*Verification: one real devnet transaction that locks CKB in escrow, then unlocks it using a genuine Reclaim proof of a genuine M-Pesa payment.*

**Week 4 — Web app.** Phoenix/LiveView UI over the above: CCC wallet connect via a JS hook, Phoenix-indexed offer list/create/accept, Reclaim JS SDK proof flow, submit unlock tx; plus the JSON API surface Week 6's Flutter app will consume. Deploy the contract to CKB testnet, and deploy Phoenix itself somewhere reachable for the pilot (a small always-on host — Fly.io is the path of least resistance for a Phoenix app, but this is Ken's call at deploy time).
*Verification: one full offer→pay→prove→unlock cycle completed through the web UI on testnet, by Ken, with real money.*

**Week 5 — Pilot.** Recruit 3–5 real testers who specifically want CKB — the Builder Track cohort and CKB community members are the honest audience here (see "Honest positioning" above: generic Binance-using P2P traders have no real reason to switch, so recruiting from that pool would overstate the MVP's actual pull) — to run real small-value trades through the web app. This is the grant's scored "user testing" deliverable — plan it as seriously as the code. Collect structured feedback (what broke, what was confusing, would they use it again, and specifically whether "I wanted CKB and had no other clean way to get it" held up as their real motivation).
*Verification: N completed real trades by people who are not Ken, with notes on what failed and what didn't.*

**Week 6 — Mobile app + writeup.** If Week 5 pilot feedback didn't surface a blocking issue: build the Flutter app against Phoenix's JSON API, with the direct requestUrl/statusUrl Reclaim flow and the deep-link-out CCC wallet-connect flow described above, reusing the same contract and provider. Otherwise, spend the week fixing what the pilot found instead. Either way: write the grant report, record a demo (the offer→pay→prove→unlock cycle end to end), and publish the repo.
*Verification: grant deliverable submitted; repo is public and buildable from a clean checkout by someone else.*

**Buffer**: if the 1-month end of the range is the real deadline, compress Weeks 5–6 into one week (smaller pilot, mobile app becomes explicitly a "next steps" line in the report rather than shipped code) rather than cutting Week 1's de-risking step or Week 5's pilot entirely — those two are what the grant is actually scoring.

## Risks & cut list, in order of what goes first if behind schedule

1. **Mobile app** — cut first; the request/poll shape of the Reclaim flow and the deep-link CCC pattern mean this was always meant to be addable after the web app proves the core out, not core itself.
2. **Additional networks** (Orange Money, MTN MoMo, etc.) — never in scope for this grant; explicitly a post-grant roadmap item already.
3. **Real pilot size** — shrink from 5 testers to 2–3 rather than cutting it; a token pilot still satisfies the scoring criterion, skipping it entirely does not.
4. **What cannot be cut**: Week 1's real-proof validation and Week 2–3's real contract + real proof integration — these are the technical core the whole pitch depends on, and the two hardest things to fake convincingly in a grant report.

**Named technical risk to watch (contract):** the secp256k1-ECDSA-recovery-plus-Keccak256-in-`no_std` verification (contract design point 2) is the one piece here without a direct existing-code precedent in Ken's own workspace (Type ID reuses a library function; this needs two crypto primitives assembled from general-purpose crates). Budget real time for it in Week 2. Checked the originally-planned fallback directly: CKB's own `ckb-crypto` crate does wrap secp256k1, but via FFI to the C `libsecp256k1` (same shape as the mainline `rust-secp256k1` crate) — a real GitHub issue (`rust-bitcoin/rust-secp256k1#654`) documents exactly this kind of C-FFI secp256k1 crate failing to build for a RISC-V target, with `k256` (pure Rust, no C dependency) reported working as the fix. So **`ckb-crypto` is not the fallback here — it likely has the same RISC-V friction, and `k256` is the primary plan, not a fallback from it.** If `k256` or `sha3` still don't build cleanly for `riscv64imac-unknown-none-elf` in practice, the next thing to try is Parity's `libsecp256k1` (`paritytech/libsecp256k1`), a separate pure-Rust secp256k1 implementation with explicit `no_std` support, used by Substrate/Polkadot for the same class of embedded on-chain ECDSA verification.

**Named technical risk to watch (mobile):** neither of Flutter's two external integrations — Reclaim proof generation, CKB wallet connect — has an official, currently-maintained platform SDK (`reclaim_sdk` is archived; JoyID's "Native App" docs page is a stub). Both are mitigated by the same "hop out to a URL, come back via deep link" pattern rather than an embedded SDK, which is lower-maintenance than it sounds, but it's still unverified in practice until Week 6 actually builds it — if it turns out messier than expected, that's exactly why mobile is the first cut, not a late-discovered blocker on the whole grant.

## Grant application checklist

Read the primary source directly — [CKB Eco Fund | Spark Program: Mini-Grant Initiative](https://talk.nervos.org/t/ckb-eco-fund-spark-program-mini-grant-initiative/8752) on Nervos Talk — which resolves both items that were previously open questions:

- [x] **Deadline/cycle timing — resolved.** No fixed deadline; it's a rolling/continuous program. Submit directly in the Spark Program channel; the evaluation committee completes assessment within **1 week** of submission. The plan's "~1 week" assumption was correct.
- [x] **Bilingual EN/中文 requirement — resolved, and no longer applies.** It *was* mandatory originally, but a later (April 2026) forum clarification dropped the requirement now that the forum has AI translation built in — submitting in English only is fine.
- [ ] **Target the $2,000 tier explicitly, not $1,000** — the forum post draws a real distinction: single-category projects (pure technical *or* pure user-testing) cap at $1,000; **comprehensive projects cap at $2,000**. This plan is comprehensive (real contract + real proof integration + a scored pilot), so the application should explicitly frame itself that way to justify the higher tier rather than leaving it implicit.
- [ ] **Address the "Web5 philosophy" scoring criterion directly** — the forum post lists it as one of five explicit evaluation criteria (alongside technical feasibility/innovation, user-testing/operational plan, team capability, and community value). Ken should look up how CKB Eco Fund specifically defines "Web5" and make sure the pitch's language connects to it, rather than assuming the trustless/no-custodian framing already covers it implicitly.
- [ ] Verified GitHub repo for the new project (anti-fraud requirement, confirmed both in this forum post and in earlier research)
- [ ] Match the confirmed deliverable list exactly: open-source code repo, documentation, a demonstration, and a project summary report with a **transparent funding-usage breakdown** (this last part — accounting for how the $1–2k was spent — wasn't previously called out and needs a line item in the Week 6 writeup)
- [ ] Note the funding is paid in **CKB, or CKB + USDI (USDI portion ≤ 50%)** — not USD directly; irrelevant to the build itself but worth knowing going in
- [ ] The 1–2 month window allows an **extension of up to 2 weeks** if requested — a real buffer beyond what "Buffer" above already assumes, worth keeping in reserve rather than planning around from the start
- [ ] Frame the pitch explicitly as complementary to Dular, not competing with it — **contingent on resolving the Dular verification flag above first**
- [ ] Frame the pitch honestly as "the only clean way to get CKB with M-Pesa, with no operator who can freeze funds or fake a dispute" — cite the April 2026 Kenya Binance-freeze incident directly (see Honest positioning above) rather than a vague claim
- [ ] Lead the "user testing and operational plan" section with Week 5's pilot design — this is scored, not optional
