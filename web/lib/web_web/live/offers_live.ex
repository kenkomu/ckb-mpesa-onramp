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
     |> assign(create_form: to_form(%{"recipient_hash" => "", "amount" => ""}))
     |> load_offers()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_offers(socket)}
  end

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb}, socket) do
    {:noreply, assign(socket, wallet: %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb}, wallet_error: nil)}
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message)}
  end

  def handle_event("create_offer", %{"recipient_hash" => recipient_hash, "amount" => amount}, socket) do
    with {:ok, recipient_hash} <- validate_hash32(recipient_hash),
         {amount, ""} <- Integer.parse(amount) do
      {:noreply,
       socket
       |> assign(busy: :create, notice: nil, tx_error: nil)
       |> push_event("run_create_offer", %{recipient_hash: recipient_hash, amount: amount})}
    else
      _ -> {:noreply, assign(socket, tx_error: "Recipient hash must be 0x followed by 64 hex characters, and amount a whole number.")}
    end
  end

  def handle_event("reserve_offer", %{"tx_hash" => tx_hash, "index" => index}, socket) do
    case find_offer(socket, tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "That offer isn't listed anymore -- try refreshing.")}

      offer ->
        {:noreply,
         socket
         |> assign(busy: :reserve, notice: nil, tx_error: nil)
         |> push_event("run_reserve_offer", %{offer: offer_json(offer)})}
    end
  end

  def handle_event("claim_offer", %{"tx_hash" => tx_hash, "index" => index}, socket) do
    case find_offer(socket, tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "That offer isn't listed anymore -- try refreshing.")}

      offer ->
        tx_id_seed = "ui-claim-#{System.system_time()}"

        {:noreply,
         socket
         |> assign(busy: :claim, notice: nil, tx_error: nil)
         |> push_event("run_claim_offer", %{offer: offer_json(offer), tx_id_seed: tx_id_seed})}
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

  defp find_offer(socket, tx_hash, index) do
    Enum.find(socket.assigns.offers, fn o -> o.out_point["tx_hash"] == tx_hash and o.out_point["index"] == index end)
  end

  defp offer_json(offer) do
    %{
      out_point: offer.out_point,
      capacity_shannon: offer.capacity_shannon,
      witness_address: offer.witness_address,
      recipient_hash: offer.recipient_hash,
      amount: offer.amount,
      registry_type_hash: offer.registry_type_hash,
      offer_guard_type_hash: offer.offer_guard_type_hash,
      status: offer.status,
      reserved_by_lock_hash: offer.reserved_by_lock_hash
    }
  end

  defp validate_hash32("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _} -> {:ok, "0x" <> hex}
      :error -> :error
    end
  end

  defp validate_hash32(_), do: :error

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="mx-auto max-w-5xl space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">Bitshada -- Open offers</h1>
          <p class="text-sm opacity-70">Buy and sell CKB for KES, escrowed on-chain -- no database, no custodian.</p>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body py-3 px-4">
            <div :if={@wallet} class="flex items-center gap-3">
              <div class="badge badge-success badge-sm">connected</div>
              <div class="text-right">
                <div class="font-mono text-xs opacity-70">{short_hash(@wallet.address)}</div>
                <div class="font-semibold">{format_ckb(@wallet.balance_ckb)} CKB</div>
              </div>
            </div>
            <div :if={@wallet == nil and @wallet_error == nil} class="flex items-center gap-2 text-sm opacity-70">
              <span class="loading loading-spinner loading-xs"></span> Connecting wallet...
            </div>
            <div :if={@wallet_error} class="text-sm text-error">Wallet unavailable: {@wallet_error}</div>
          </div>
        </div>
      </div>

      <div :if={@notice} class="alert alert-success shadow-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <span class="font-mono text-sm">{@notice}</span>
      </div>
      <div :if={@tx_error} class="alert alert-error shadow-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span class="text-sm">{@tx_error}</span>
      </div>
      <div :if={@error} class="alert alert-error shadow-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span class="text-sm">Could not reach the CKB node: {inspect(@error)}</span>
      </div>

      <div class="card bg-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Sell CKB for KES</h2>
          <.form :if={@wallet} for={@create_form} phx-submit="create_offer" class="flex flex-wrap items-end gap-3">
            <label class="flex-1 min-w-56 form-control">
              <span class="label-text text-xs opacity-70">Recipient hash (0x + 64 hex)</span>
              <input type="text" name="recipient_hash" class="input input-bordered input-sm w-full" placeholder="0x0707...0707" />
            </label>
            <label class="form-control">
              <span class="label-text text-xs opacity-70">Amount (KES minor units)</span>
              <input type="text" name="amount" class="input input-bordered input-sm w-32" placeholder="25000" />
            </label>
            <.button type="submit" disabled={@busy == :create} phx-disable-with="Creating..." class="btn-primary">
              <span :if={@busy == :create} class="loading loading-spinner loading-xs"></span>
              {if @busy == :create, do: "Creating...", else: "Create offer"}
            </.button>
          </.form>
          <p :if={@wallet == nil} class="text-sm opacity-60">Connect a wallet to create an offer.</p>
        </div>
      </div>

      <div :if={@error == nil and @offers == []} class="text-center opacity-60 py-12">
        No open offers right now -- create one above.
      </div>

      <div :if={@offers != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div :for={offer <- @offers} class="card bg-base-200 shadow-sm">
          <div class="card-body gap-2">
            <div class="flex items-center justify-between">
              <span class={["badge", offer.status == :open && "badge-success", offer.status == :reserved && "badge-warning"]}>
                {offer.status}
              </span>
              <span class="text-xs opacity-50 font-mono">{short_hash(offer.out_point["tx_hash"])}:{offer.out_point["index"]}</span>
            </div>

            <div class="text-2xl font-bold">{format_amount(offer.amount)} <span class="text-sm font-normal opacity-60">KES</span></div>
            <div class="text-sm opacity-70">{format_capacity(offer.capacity_shannon)} locked in escrow</div>
            <div class="text-xs opacity-50 font-mono">Recipient: {short_hash(offer.recipient_hash)}</div>

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
                class="text-xs opacity-50 w-full text-center py-1"
              >
                Reserved by another buyer
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="flex justify-center pt-2">
        <.button phx-click="refresh" class="btn-ghost btn-sm">Refresh</.button>
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
