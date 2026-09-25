defmodule WebWeb.OffersLive do
  @moduledoc """
  The open-offers marketplace: reads live mpesa-escrow cells straight off
  the configured CKB node (Phoenix never touches a private key for this
  part -- see Web.Ckb.Offers's own moduledoc), and lets a connected
  wallet create/reserve/claim offers through the browser.

  The actual signing happens client-side, in assets/js/ckb.js, via the
  real CCC SDK (`ccc.SignerCkbPrivateKey` -- a devnet-appropriate
  stand-in for JoyID, which has no way to reach a private local devnet;
  see ckb.js's own header comment). This LiveView only relays: the
  `Wallet` JS hook (assets/js/wallet_hook.js) pushes the params for a
  transaction over `run_*` events, ckb.js builds/signs/submits it in the
  browser (assets/js/chain_errors.js turns any failure into plain
  language first), and the hook pushes the resulting tx hash or message
  back here via `tx_success`/`tx_error`.
  """

  use WebWeb, :live_view

  alias Web.Ckb.Offers

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(wallet: nil, wallet_error: nil, busy: nil, notice: nil, tx_error: nil)
     |> assign(create_form: to_form(%{"identifier" => "", "amount" => ""}))
     |> load_offers()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(notice: nil, tx_error: nil) |> load_offers()}
  end

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb}, socket) do
    {:noreply, assign(socket, wallet: %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb}, wallet_error: nil)}
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message)}
  end

  def handle_event("create_offer", %{"identifier" => identifier, "amount" => amount_kes}, socket) do
    with {:ok, identifier} <- Offers.validate_identifier(identifier),
         {:ok, minor_units} <- Offers.parse_kes(amount_kes) do
      {:noreply,
       socket
       |> assign(busy: :create, notice: nil, tx_error: nil)
       |> push_event("run_create_offer", %{identifier: identifier, amount: minor_units})}
    else
      _ -> {:noreply, assign(socket, tx_error: "Enter an M-Pesa number (or any test value) and an amount in KES.")}
    end
  end

  def handle_event("reserve_offer", %{"tx_hash" => tx_hash, "index" => index}, socket) do
    case Offers.find(tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "That offer isn't listed anymore -- try refreshing.")}

      offer ->
        {:noreply,
         socket
         |> assign(busy: :reserve, notice: nil, tx_error: nil)
         |> push_event("run_reserve_offer", %{offer: Offers.to_json(offer)})}
    end
  end

  def handle_event("claim_offer", %{"tx_hash" => tx_hash, "index" => index}, socket) do
    case Offers.find(tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "That offer isn't listed anymore -- try refreshing.")}

      offer ->
        tx_id_seed = "ui-claim-#{System.system_time()}"

        {:noreply,
         socket
         |> assign(busy: :claim, notice: nil, tx_error: nil)
         |> push_event("run_claim_offer", %{offer: Offers.to_json(offer), tx_id_seed: tx_id_seed})}
    end
  end

  def handle_event("tx_success", %{"action" => action, "tx_hash" => tx_hash}, socket) do
    {:noreply,
     socket
     |> assign(busy: nil, notice: "#{action_label(action)} submitted: #{tx_hash}", tx_error: nil)
     |> load_offers()}
  end

  def handle_event("tx_error", %{"action" => action, "message" => message}, socket) do
    {:noreply, assign(socket, busy: nil, notice: nil, tx_error: "#{action_label(action)} failed: #{message}")}
  end

  defp action_label("create"), do: "Create"
  defp action_label("reserve"), do: "Reserve"
  defp action_label("claim"), do: "Claim"
  defp action_label(other), do: other

  defp load_offers(socket) do
    case Offers.list() do
      {:ok, offers} -> assign(socket, offers: offers, error: nil)
      {:error, reason} -> assign(socket, offers: [], error: reason)
    end
  end

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="space-y-8">
      <div class="alert bg-warning/10 border border-warning/30 text-warning-content shadow-sm">
        <.icon name="hero-beaker" class="size-5 text-warning" />
        <span class="text-sm">
          <strong>Testnet pilot.</strong> Everything here uses test CKB with no real-world value &mdash; nothing you do on this page moves real money.
        </span>
      </div>

      <div class="flex flex-wrap items-start justify-between gap-5">
        <div>
          <div class="font-mono text-xs uppercase tracking-widest text-primary font-semibold mb-1">
            Marketplace
          </div>
          <h1 class="font-display text-3xl font-bold tracking-tight">Open offers</h1>
          <p class="text-sm text-base-content/70 mt-1 max-w-md">
            Buy and sell CKB for KES, escrowed on-chain &mdash; no database, no custodian.
          </p>
        </div>

        <div class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body py-3 px-4 min-w-56">
            <div :if={@wallet} class="flex items-center gap-3">
              <span class="relative flex size-2.5">
                <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60">
                </span>
                <span class="relative inline-flex size-2.5 rounded-full bg-success"></span>
              </span>
              <div class="text-right ml-auto">
                <div class="font-mono text-xs text-base-content/60">{short_hash(@wallet.address)}</div>
                <div class="font-mono font-semibold tabular-nums">{format_ckb(@wallet.balance_ckb)} CKB</div>
              </div>
            </div>
            <div :if={@wallet == nil and @wallet_error == nil} class="flex items-center gap-2 text-sm text-base-content/60">
              <span class="loading loading-spinner loading-xs"></span> Connecting wallet...
            </div>
            <div :if={@wallet_error} class="text-sm text-error">Wallet unavailable: {@wallet_error}</div>
          </div>
        </div>
      </div>

      <div :if={@wallet && @wallet.balance_ckb < 10} class="alert bg-info/10 border border-info/30 shadow-sm">
        <.icon name="hero-information-circle" class="size-5 text-info" />
        <div class="text-sm">
          <strong>Your wallet needs testnet CKB before you can create, reserve, or claim an offer.</strong>
          <div class="mt-1">
            Copy your address
            <button
              type="button"
              class="font-mono underline decoration-dotted"
              onclick={"navigator.clipboard.writeText('#{@wallet.address}')"}
            >
              {short_hash(@wallet.address)}
            </button>
            and email it to
            <a
              class="link"
              href={"mailto:kenneth.njoroge@quantumke.org?subject=Bitshada%20testnet%20funding&body=Please%20fund%20my%20wallet%3A%20" <> @wallet.address}
            >kenneth.njoroge@quantumke.org</a>
            &mdash; you'll get a small top-up so you can actually try the flow.
          </div>
        </div>
      </div>

      <div :if={@notice} class="alert alert-success shadow-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <span class="font-mono text-sm break-all">{@notice}</span>
      </div>
      <div :if={@tx_error} class="alert alert-error shadow-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span class="text-sm">{@tx_error}</span>
      </div>
      <div :if={@error} class="alert alert-error shadow-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span class="text-sm">Could not reach the CKB node: {inspect(@error)}</span>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body gap-1.5">
            <div class="flex items-center gap-2">
              <span class="flex size-7 items-center justify-center rounded-full bg-primary/15 text-primary font-mono text-xs font-bold">1</span>
              <.icon name="hero-lock-closed" class="size-4 text-primary" />
            </div>
            <h3 class="font-display font-semibold">Sellers lock CKB</h3>
            <p class="text-sm text-base-content/70">Escrow on-chain and name the KES price &mdash; that's the form below.</p>
          </div>
        </div>
        <div class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body gap-1.5">
            <div class="flex items-center gap-2">
              <span class="flex size-7 items-center justify-center rounded-full bg-primary/15 text-primary font-mono text-xs font-bold">2</span>
              <.icon name="hero-hand-raised" class="size-4 text-primary" />
            </div>
            <h3 class="font-display font-semibold">Buyers reserve</h3>
            <p class="text-sm text-base-content/70">
              Click <span class="font-mono">Reserve</span> for first dibs, then send KES via M-Pesa off-chain.
            </p>
          </div>
        </div>
        <div class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body gap-1.5">
            <div class="flex items-center gap-2">
              <span class="flex size-7 items-center justify-center rounded-full bg-primary/15 text-primary font-mono text-xs font-bold">3</span>
              <.icon name="hero-check-badge" class="size-4 text-primary" />
            </div>
            <h3 class="font-display font-semibold">Buyer claims</h3>
            <p class="text-sm text-base-content/70">
              Click <span class="font-mono">Claim</span> and the contract releases CKB straight to their wallet.
            </p>
          </div>
        </div>
      </div>

      <div class="card bg-base-200 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="font-display text-lg font-semibold">Sell CKB for KES</h2>
          <.form :if={@wallet} for={@create_form} phx-submit="create_offer" class="flex flex-wrap items-end gap-3 mt-1">
            <label class="flex-1 min-w-56 form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">M-Pesa number (any test value works)</span>
              <input
                type="text"
                name="identifier"
                class="input input-bordered input-sm w-full"
                placeholder="0712 345 678"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">Amount (KES)</span>
              <input type="text" name="amount" class="input input-bordered input-sm w-32" placeholder="250" />
            </label>
            <.button type="submit" disabled={@busy == :create} phx-disable-with="Creating..." class="btn-primary">
              <span :if={@busy == :create} class="loading loading-spinner loading-xs"></span>
              {if @busy == :create, do: "Creating...", else: "Create offer"}
            </.button>
          </.form>
          <p :if={@wallet == nil} class="text-sm text-base-content/60 mt-1">Connect a wallet to create an offer.</p>
        </div>
      </div>

      <div :if={@error == nil and @offers == []} class="flex flex-col items-center gap-2 text-center py-16">
        <.icon name="hero-inbox" class="size-8 text-base-content/30" />
        <p class="text-base-content/60">No open offers right now &mdash; create one above.</p>
      </div>

      <div :if={@offers != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div
          :for={offer <- @offers}
          class="motion-safe:animate-fade-slide-up card bg-base-200 border border-base-300 shadow-sm transition-all duration-200 hover:shadow-md hover:border-primary/40 hover:-translate-y-0.5"
        >
          <div class="card-body gap-2">
            <div class="flex items-center justify-between">
              <span class={[
                "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-mono font-semibold",
                offer.status == :open && "bg-success/15 text-success",
                offer.status == :reserved && "bg-warning/15 text-warning"
              ]}>
                <span class={[
                  "size-1.5 rounded-full",
                  offer.status == :open && "bg-success",
                  offer.status == :reserved && "bg-warning"
                ]}>
                </span>
                {offer.status}
              </span>
              <span class="text-xs text-base-content/50 font-mono">
                {short_hash(offer.out_point["tx_hash"])}:{offer.out_point["index"]}
              </span>
            </div>

            <div class="font-mono text-2xl font-bold tabular-nums">
              {format_amount(offer.amount)} <span class="text-sm font-normal text-base-content/60">KES</span>
            </div>
            <div class="text-sm text-base-content/70 font-mono tabular-nums">
              {format_capacity(offer.capacity_shannon)} locked in escrow
            </div>
            <div class="text-xs text-base-content/50 font-mono">Recipient: {short_hash(offer.recipient_hash)}</div>

            <div class="card-actions mt-2">
              <.button
                :if={@wallet && offer.status == :open}
                phx-click="reserve_offer"
                phx-value-tx_hash={offer.out_point["tx_hash"]}
                phx-value-index={offer.out_point["index"]}
                disabled={@busy == :reserve}
                phx-disable-with="Reserving..."
                class="btn-primary btn-sm w-full"
              >
                <span :if={@busy == :reserve} class="loading loading-spinner loading-xs"></span>
                {if @busy == :reserve, do: "Reserving...", else: "Reserve"}
              </.button>
              <.button
                :if={@wallet && offer.status == :reserved && offer.reserved_by_lock_hash == @wallet.lock_hash}
                phx-click="claim_offer"
                phx-value-tx_hash={offer.out_point["tx_hash"]}
                phx-value-index={offer.out_point["index"]}
                disabled={@busy == :claim}
                phx-disable-with="Claiming..."
                class="btn-primary btn-sm w-full"
              >
                <span :if={@busy == :claim} class="loading loading-spinner loading-xs"></span>
                {if @busy == :claim, do: "Claiming...", else: "Claim"}
              </.button>
              <div
                :if={offer.status == :reserved && (@wallet == nil || offer.reserved_by_lock_hash != @wallet.lock_hash)}
                class="text-xs text-base-content/50 w-full text-center py-1"
              >
                Reserved by another buyer
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="flex justify-center pt-2">
        <.button phx-click="refresh" phx-disable-with="Refreshing..." class="btn-ghost btn-sm">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </.button>
      </div>
    </div>
    """
  end

  defp format_amount(minor_units), do: :erlang.float_to_binary(minor_units / 100, decimals: 2)
  defp format_capacity(shannon), do: format_ckb(shannon / 100_000_000) <> " CKB"
  defp format_ckb(ckb), do: :erlang.float_to_binary(ckb / 1, decimals: 2)

  defp short_hash("0x" <> hex), do: "0x" <> String.slice(hex, 0, 8) <> "..."
  defp short_hash(other), do: other
end
