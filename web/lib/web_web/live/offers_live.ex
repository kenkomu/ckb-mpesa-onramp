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

  alias Web.Ckb.{OfferDirectory, Offers, Phone}

  @tick_ms 30_000

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     socket
     |> assign(now: System.os_time(:second))
     |> assign(tab: :buy, wallet: nil, wallet_error: nil, busy: nil, notice: nil, tx_error: nil)
     |> assign(faucet_busy: false, faucet_notice: nil, faucet_error: nil)
     |> assign(create_form: to_form(%{"identifier" => "", "amount" => ""}))
     |> load_offers()}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign(socket, now: System.os_time(:second))}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ["buy", "sell"] do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(notice: nil, tx_error: nil) |> load_offers()}
  end

  def handle_event(
        "wallet_ready",
        %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb, "lockArgs" => lock_args},
        socket
      ) do
    wallet = %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb, lock_args: lock_args}
    {:noreply, assign(socket, wallet: wallet, wallet_error: nil)}
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message)}
  end

  def handle_event("request_faucet", _params, socket) do
    case socket.assigns.wallet do
      nil ->
        {:noreply, socket}

      wallet ->
        # Real testnet commits have taken 15-30s+ in this project's own
        # testing, and Web.Ckb.Faucet.request/1 blocks on that -- run it
        # via start_async so the `faucet_busy` spinner actually renders
        # right away instead of the whole handle_event blocking before
        # LiveView gets a chance to push the diff.
        {:noreply,
         socket
         |> assign(faucet_busy: true, faucet_notice: nil, faucet_error: nil)
         |> start_async(:faucet, fn -> Web.Ckb.Faucet.request(wallet.lock_args) end)}
    end
  end

  def handle_event("create_offer", %{"identifier" => identifier, "amount" => amount_kes}, socket) do
    with {:ok, identifier} <- Offers.validate_identifier(identifier),
         {:ok, minor_units} <- Offers.parse_kes(amount_kes) do
      OfferDirectory.register(OfferDirectory.hash(identifier), identifier, socket.assigns.wallet && socket.assigns.wallet.lock_hash)

      {:noreply,
       socket
       |> assign(busy: :create, notice: nil, tx_error: nil)
       |> push_event("run_create_offer", %{identifier: identifier, amount: minor_units})}
    else
      _ ->
        {:noreply,
         assign(socket,
           tx_error:
             "Enter a valid Kenyan M-Pesa number (like 0712 345 678 or +254 712 345 678) and an amount in KES."
         )}
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

  def handle_event("clear_reservation", %{"tx_hash" => tx_hash, "index" => index}, socket),
    do: offer_action(socket, tx_hash, index, :clear, "run_clear_reservation")

  def handle_event("reclaim_offer", %{"tx_hash" => tx_hash, "index" => index}, socket),
    do: offer_action(socket, tx_hash, index, :reclaim, "run_reclaim_offer")

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
     |> assign(tab: if(action in ["create", "reclaim"], do: :sell, else: :buy))
     |> load_offers()}
  end

  def handle_event("tx_error", %{"action" => action, "message" => message}, socket) do
    {:noreply, assign(socket, busy: nil, notice: nil, tx_error: "#{action_label(action)} failed: #{message}")}
  end

  def handle_async(:faucet, {:ok, result}, socket) do
    socket =
      case result do
        {:ok, tx_hash} ->
          socket
          |> assign(faucet_busy: false, faucet_notice: "Sent 600 testnet CKB: #{tx_hash}")
          |> push_event("refresh_wallet", %{})

        {:error, :cooldown, seconds_remaining} ->
          hours = div(seconds_remaining, 3600)
          assign(socket, faucet_busy: false, faucet_error: "Already funded recently -- try again in about #{hours + 1}h.")

        {:error, reason} ->
          assign(socket, faucet_busy: false, faucet_error: "#{reason}")
      end

    {:noreply, socket}
  end

  def handle_async(:faucet, {:exit, reason}, socket) do
    {:noreply, assign(socket, faucet_busy: false, faucet_error: "Faucet request failed: #{inspect(reason)}")}
  end

  defp action_label("create"), do: "Create"
  defp action_label("reserve"), do: "Reserve"
  defp action_label("claim"), do: "Claim"
  defp action_label("clear"), do: "Reopen"
  defp action_label("reclaim"), do: "Take back"
  defp action_label(other), do: other

  defp offer_action(socket, tx_hash, index, busy, event) do
    case Offers.find(tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "That offer isn't listed anymore -- try refreshing.")}

      offer ->
        {:noreply,
         socket
         |> assign(busy: busy, notice: nil, tx_error: nil)
         |> push_event(event, %{offer: Offers.to_json(offer)})}
    end
  end

  defp load_offers(socket) do
    case Offers.list() do
      {:ok, offers} -> assign(socket, offers: offers, directory: directory_for(offers), error: nil)
      {:error, reason} -> assign(socket, offers: [], directory: %{}, error: reason)
    end
  end

  defp directory_for(offers) do
    Map.new(offers, fn offer -> {offer.recipient_hash, OfferDirectory.lookup(offer.recipient_hash)} end)
  end

  defp mine_reserved(offers, nil), do: Enum.reject(offers, fn _ -> true end)

  defp mine_reserved(offers, wallet),
    do: Enum.filter(offers, &(&1.status == :reserved and &1.reserved_by_lock_hash == wallet.lock_hash))

  defp my_sales(_offers, nil), do: []
  defp my_sales(offers, wallet), do: Enum.filter(offers, &(&1.seller_lock_hash == wallet.lock_hash))

  defp expired?(offer, now), do: offer.status == :reserved and offer.reserved_until <= now

  defp buy_list(offers, wallet) do
    mine = my_sales(offers, wallet) ++ mine_reserved(offers, wallet)
    Enum.reject(offers, &(&1 in mine))
  end

  defp minutes_left(until, now), do: max(div(until - now + 59, 60), 0)

  defp format_time(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%d %b %H:%M UTC")

  defp seller_number(directory, offer) do
    case directory[offer.recipient_hash] do
      %{number: number} -> Phone.display(number)
      _ -> nil
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
            <button
              :if={@wallet}
              type="button"
              title="Tap to copy your full wallet address"
              class="flex items-center gap-3 cursor-pointer"
              onclick={"navigator.clipboard.writeText('#{@wallet.address}')"}
            >
              <span class="relative flex size-2.5">
                <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60">
                </span>
                <span class="relative inline-flex size-2.5 rounded-full bg-success"></span>
              </span>
              <div class="text-right ml-auto">
                <div class="font-mono text-xs text-base-content/60 underline decoration-dotted">{short_hash(@wallet.address)}</div>
                <div class="font-mono font-semibold tabular-nums">{format_ckb(@wallet.balance_ckb)} CKB</div>
              </div>
            </button>
            <div :if={@wallet == nil and @wallet_error == nil} class="flex items-center gap-2 text-sm text-base-content/60">
              <span class="loading loading-spinner loading-xs"></span> Connecting wallet...
            </div>
            <div :if={@wallet_error} class="text-sm text-error">Wallet unavailable: {@wallet_error}</div>
          </div>
        </div>
      </div>

      <div :if={@wallet && @wallet.balance_ckb < 10} class="alert bg-info/10 border border-info/30 shadow-sm">
        <.icon name="hero-information-circle" class="size-5 text-info" />
        <div class="text-sm flex-1">
          <strong>Your wallet needs testnet CKB before you can create, reserve, or claim an offer.</strong>
          <div class="mt-1">Tap below for an instant, free top-up -- no need to ask anyone.</div>
        </div>
        <.button phx-click="request_faucet" disabled={@faucet_busy} phx-disable-with="Sending..." class="btn-primary btn-sm">
          <span :if={@faucet_busy} class="loading loading-spinner loading-xs"></span>
          {if @faucet_busy, do: "Sending...", else: "Get testnet CKB"}
        </.button>
      </div>
      <div :if={@faucet_notice} class="alert alert-success shadow-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <span class="font-mono text-sm break-all">{@faucet_notice}</span>
      </div>
      <div :if={@faucet_error} class="alert bg-warning/10 border border-warning/30 shadow-sm">
        <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
        <span class="text-sm">{@faucet_error}</span>
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

      <div role="tablist" class="tabs tabs-boxed w-fit">
        <button role="tab" phx-click="set_tab" phx-value-tab="buy" class={["tab", @tab == :buy && "tab-active"]}>
          Buy CKB
        </button>
        <button role="tab" phx-click="set_tab" phx-value-tab="sell" class={["tab", @tab == :sell && "tab-active"]}>
          Sell CKB
        </button>
      </div>

      <%!-- ============ BUY ============ --%>
      <div :if={@tab == :buy} class="space-y-6">
        <p class="text-sm text-base-content/70 max-w-xl">
          Pay a seller in KES via M-Pesa and receive their CKB. <strong>1.</strong> Reserve an offer.
          <strong>2.</strong> Send the exact KES amount to the seller's number. <strong>3.</strong> Come back and claim your CKB.
        </p>

        <div :for={offer <- mine_reserved(@offers, @wallet)} class="card bg-primary/5 border-2 border-primary/40 shadow-sm">
          <div class="card-body gap-3">
            <div class="font-display font-semibold">Your reservation &mdash; pay now</div>
            <div :if={seller_number(@directory, offer)} class="space-y-1">
              <div class="text-sm text-base-content/70">Send exactly</div>
              <div class="font-mono text-3xl font-bold tabular-nums">
                {format_amount(offer.amount)} <span class="text-base font-normal">KES</span>
              </div>
              <div class="text-sm text-base-content/70">via M-Pesa to</div>
              <button
                type="button"
                class="font-mono text-2xl font-bold underline decoration-dotted cursor-pointer"
                title="Tap to copy"
                onclick={"navigator.clipboard.writeText('#{seller_number(@directory, offer)}'.replaceAll(' ',''))"}
              >
                {seller_number(@directory, offer)}
              </button>
            </div>
            <div :if={!seller_number(@directory, offer)} class="text-sm text-warning">
              The seller's number isn't available for this older offer. Please reserve a newer one.
            </div>
            <p :if={!expired?(offer, @now)} class="text-xs text-warning font-semibold">
              Reserved for you for {minutes_left(offer.reserved_until, @now)} more min &mdash; send the money before then.
            </p>
            <p :if={expired?(offer, @now)} class="text-xs text-warning font-semibold">
              Your 20 minutes are up. If you've already paid, you can still claim until someone reopens the offer.
            </p>
            <p class="text-xs text-base-content/60">
              Only tap Claim after you've sent the money. You'll receive {format_capacity(offer.capacity_shannon)}.
            </p>
            <.button
              phx-click="claim_offer"
              phx-value-tx_hash={offer.out_point["tx_hash"]}
              phx-value-index={offer.out_point["index"]}
              disabled={@busy == :claim}
              phx-disable-with="Claiming..."
              class="btn-primary w-full"
            >
              <span :if={@busy == :claim} class="loading loading-spinner loading-xs"></span>
              {if @busy == :claim, do: "Claiming...", else: "I've paid -- Claim my CKB"}
            </.button>
          </div>
        </div>

        <% listed = Enum.filter(buy_list(@offers, @wallet), &(&1.status == :open))
        taken = Enum.filter(buy_list(@offers, @wallet), &(&1.status == :reserved and not expired?(&1, @now)))
        expired = Enum.filter(buy_list(@offers, @wallet), &expired?(&1, @now)) %>
        <div :if={@error == nil and listed == [] and expired == [] and mine_reserved(@offers, @wallet) == []} class="flex flex-col items-center gap-2 text-center py-12">
          <.icon name="hero-inbox" class="size-8 text-base-content/30" />
          <p class="text-base-content/60">No offers available right now. Check back soon, or sell some CKB yourself.</p>
        </div>

        <div :if={listed != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div :for={offer <- listed} class="card bg-base-200 border border-base-300 shadow-sm">
            <div class="card-body gap-2">
              <.status_badge status={offer.status} />
              <div class="font-mono text-2xl font-bold tabular-nums">
                {format_amount(offer.amount)} <span class="text-sm font-normal text-base-content/60">KES</span>
              </div>
              <div class="text-sm text-base-content/70 font-mono tabular-nums">
                You get {format_capacity(offer.capacity_shannon)}
              </div>
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
              </div>
            </div>
          </div>
        </div>

        <div :if={expired != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div :for={offer <- expired} class="card bg-base-200 border border-dashed border-warning/50 shadow-sm">
            <div class="card-body gap-2">
              <span class="text-xs font-semibold text-warning">Reservation expired</span>
              <div class="font-mono text-2xl font-bold tabular-nums">
                {format_amount(offer.amount)} <span class="text-sm font-normal text-base-content/60">KES</span>
              </div>
              <p class="text-xs text-base-content/60">The buyer never completed this. Reopen it so anyone can buy.</p>
              <.button
                :if={@wallet}
                phx-click="clear_reservation"
                phx-value-tx_hash={offer.out_point["tx_hash"]}
                phx-value-index={offer.out_point["index"]}
                disabled={@busy == :clear}
                phx-disable-with="Reopening..."
                class="btn-sm btn-outline w-full"
              >
                {if @busy == :clear, do: "Reopening...", else: "Reopen offer"}
              </.button>
            </div>
          </div>
        </div>

        <details :if={taken != []} class="text-sm">
          <summary class="cursor-pointer text-base-content/60">{length(taken)} offer(s) currently reserved by other buyers</summary>
          <ul class="mt-2 space-y-1 text-base-content/60 font-mono">
            <li :for={offer <- taken}>{format_amount(offer.amount)} KES &middot; {format_capacity(offer.capacity_shannon)}</li>
          </ul>
        </details>
      </div>

      <%!-- ============ SELL ============ --%>
      <div :if={@tab == :sell} class="space-y-6">
        <div class="card bg-base-200 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="font-display text-lg font-semibold">Sell CKB for KES</h2>
            <p class="text-sm text-base-content/70">
              Lock some CKB and set a KES price. A buyer reserves it, sends you the KES on M-Pesa, then claims the CKB.
            </p>
            <.form :if={@wallet} for={@create_form} phx-submit="create_offer" class="flex flex-wrap items-end gap-3 mt-1">
              <label class="flex-1 min-w-56 form-control">
                <span class="label-text text-xs text-base-content/60 mb-1">Your M-Pesa number (the buyer pays this)</span>
                <input
                  type="tel"
                  name="identifier"
                  required
                  class="input input-bordered input-sm w-full"
                  placeholder="0712 345 678"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-xs text-base-content/60 mb-1">Price (KES)</span>
                <input type="text" inputmode="decimal" name="amount" required class="input input-bordered input-sm w-32" placeholder="250" />
              </label>
              <.button type="submit" disabled={@busy == :create} phx-disable-with="Creating..." class="btn-primary">
                <span :if={@busy == :create} class="loading loading-spinner loading-xs"></span>
                {if @busy == :create, do: "Creating...", else: "Create offer"}
              </.button>
            </.form>
            <p :if={@wallet == nil} class="text-sm text-base-content/60 mt-1">Connect a wallet to create an offer.</p>
          </div>
        </div>

        <% sales = my_sales(@offers, @wallet) %>
        <div>
          <h3 class="font-display font-semibold mb-3">My offers</h3>
          <p :if={sales == []} class="text-sm text-base-content/60">You haven't listed anything yet.</p>
          <div :if={sales != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <div :for={offer <- sales} class="card bg-base-200 border border-base-300 shadow-sm">
              <div class="card-body gap-2">
                <.status_badge status={offer.status} />
                <div class="font-mono text-2xl font-bold tabular-nums">
                  {format_amount(offer.amount)} <span class="text-sm font-normal text-base-content/60">KES</span>
                </div>
                <div class="text-sm text-base-content/70 font-mono">{format_capacity(offer.capacity_shannon)} in escrow</div>
                <div class="text-xs text-base-content/60">
                  <%= cond do %>
                    <% offer.status == :open -> %>Waiting for a buyer. Live until {format_time(offer.deadline)}.
                    <% expired?(offer, @now) -> %>The buyer's reservation expired without a claim.
                    <% true -> %>A buyer reserved this. Expect {format_amount(offer.amount)} KES on your M-Pesa.
                  <% end %>
                </div>
                <.button
                  :if={offer.deadline <= @now and (offer.status == :open or expired?(offer, @now))}
                  phx-click="reclaim_offer"
                  phx-value-tx_hash={offer.out_point["tx_hash"]}
                  phx-value-index={offer.out_point["index"]}
                  disabled={@busy == :reclaim}
                  phx-disable-with="Taking back..."
                  class="btn-sm btn-outline w-full mt-1"
                >
                  {if @busy == :reclaim, do: "Taking back...", else: "Take back my CKB"}
                </.button>
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
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex w-fit items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold",
      @status == :open && "bg-success/15 text-success",
      @status == :reserved && "bg-warning/15 text-warning"
    ]}>
      <span class={["size-1.5 rounded-full", @status == :open && "bg-success", @status == :reserved && "bg-warning"]}></span>
      {if @status == :open, do: "Available", else: "Reserved"}
    </span>
    """
  end

  defp format_amount(minor_units), do: :erlang.float_to_binary(minor_units / 100, decimals: 2)
  defp format_capacity(shannon), do: format_ckb(shannon / 100_000_000) <> " CKB"
  defp format_ckb(ckb), do: :erlang.float_to_binary(ckb / 1, decimals: 2)

  defp short_hash("0x" <> hex), do: "0x" <> String.slice(hex, 0, 8) <> "..."

  # CKB wallet addresses are bech32m (e.g. "ckt1qzda0c...", ~97 chars),
  # not 0x-prefixed hex, so they fell straight through to the catch-all
  # clause below and rendered in full -- overflowing the wallet-status
  # card on narrow screens instead of the short form every other hash
  # on this page gets.
  defp short_hash(other) when is_binary(other) and byte_size(other) > 14, do: String.slice(other, 0, 10) <> "..."
  defp short_hash(other), do: other
end
