// Bridges the LiveView page to ckb.js's real CCC transaction-building
// functions. The hook owns nothing stateful itself -- every actual
// signing/submission call lives in ckb.js; this just relays LiveView
// events to it and pushes the result back.
import { createOffer, reserveOffer, claimOffer, walletInfo } from "./ckb.js";

export const Wallet = {
  async mounted() {
    try {
      const info = await walletInfo();
      this.pushEvent("wallet_ready", info);
    } catch (err) {
      this.pushEvent("wallet_error", { message: String(err) });
    }

    this.handleEvent("run_create_offer", async ({ recipient_hash, amount }) => {
      try {
        const tx_hash = await createOffer(recipient_hash, Number(amount));
        this.pushEvent("tx_success", { action: "create", tx_hash });
      } catch (err) {
        this.pushEvent("tx_error", { action: "create", message: String(err) });
      }
    });

    this.handleEvent("run_reserve_offer", async ({ offer }) => {
      try {
        const tx_hash = await reserveOffer(offer);
        this.pushEvent("tx_success", { action: "reserve", tx_hash });
      } catch (err) {
        this.pushEvent("tx_error", { action: "reserve", message: String(err) });
      }
    });

    this.handleEvent("run_claim_offer", async ({ offer, tx_id_seed }) => {
      try {
        const tx_hash = await claimOffer(offer, tx_id_seed);
        this.pushEvent("tx_success", { action: "claim", tx_hash });
      } catch (err) {
        this.pushEvent("tx_error", { action: "claim", message: String(err) });
      }
    });
  },
};
