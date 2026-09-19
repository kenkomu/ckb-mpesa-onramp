// Bridges the LiveView page to ckb.js's real CCC transaction-building
// functions. The hook owns nothing stateful itself -- every actual
// signing/submission call lives in ckb.js; this just relays LiveView
// events to it, translates any error into plain language, and pushes
// the result back.
import { createOffer, reserveOffer, claimOffer, walletInfo, hashIdentifier } from "./ckb.js";
import { friendlyError } from "./chain_errors.js";

export const Wallet = {
  async mounted() {
    await this.refreshWallet();

    this.handleEvent("run_create_offer", async ({ identifier, amount }) => {
      await this.run("create", async () => {
        const recipientHash = await hashIdentifier(identifier);
        return createOffer(recipientHash, Number(amount));
      });
    });

    this.handleEvent("run_reserve_offer", async ({ offer }) => {
      await this.run("reserve", () => reserveOffer(offer));
    });

    this.handleEvent("run_claim_offer", async ({ offer, tx_id_seed }) => {
      await this.run("claim", () => claimOffer(offer, tx_id_seed));
    });
  },

  async refreshWallet() {
    try {
      const info = await walletInfo();
      this.pushEvent("wallet_ready", info);
    } catch (err) {
      this.pushEvent("wallet_error", { message: friendlyError(err) });
    }
  },

  async run(action, fn) {
    try {
      const tx_hash = await fn();
      this.pushEvent("tx_success", { action, tx_hash });
    } catch (err) {
      this.pushEvent("tx_error", { action, message: friendlyError(err) });
    }
    // Balance/UTXO set changed either way (spent on success, or nothing
    // changed on failure but cheap enough to just re-check).
    await this.refreshWallet();
  },
};
