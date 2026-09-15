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
  browser, and the hook pushes the resulting tx hash (or error) back
  here via `tx_success`/`tx_error`.
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

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash}, socket) do
    {:noreply, assign(socket, wallet: %{address: address, lock_hash: lock_hash})}
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
      _ -> {:noreply, assign(socket, tx_error: "recipient hash must be 0x + 64 hex chars, amount an integer")}
    end
  end

  def handle_event("reserve_offer", %{"tx_hash" => tx_hash, "index" => index}, socket) do
    case find_offer(socket, tx_hash, index) do
      nil ->
        {:noreply, assign(socket, tx_error: "offer no longer listed -- try refreshing")}

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
        {:noreply, assign(socket, tx_error: "offer no longer listed -- try refreshing")}

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
     |> assign(busy: nil, notice: "#{action} submitted: #{tx_hash}", tx_error: nil)
     |> load_offers()}
  end

  def handle_event("tx_error", %{"action" => action, "message" => message}, socket) do
    {:noreply, assign(socket, busy: nil, notice: nil, tx_error: "#{action} failed: #{message}")}
  end

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
    <div id="wallet" phx-hook="Wallet">
      <.header>
        Open offers
        <:subtitle>Live mpesa-escrow cells read straight off the CKB devnet -- no database in between.</:subtitle>
        <:actions>
          <.button phx-click="refresh">Refresh</.button>
        </:actions>
      </.header>

      <div class="mt-4">
        <div :if={@wallet} class="text-sm opacity-70">
          Wallet: <code>{@wallet.address}</code>
        </div>
        <div :if={@wallet == nil and @wallet_error == nil} class="text-sm opacity-70">
          Connecting wallet…
        </div>
        <div :if={@wallet_error} class="alert alert-error mt-2">
          Wallet unavailable: {@wallet_error}
        </div>
      </div>

      <div :if={@notice} class="alert alert-success mt-4">{@notice}</div>
      <div :if={@tx_error} class="alert alert-error mt-4">{@tx_error}</div>

      <div :if={@error} class="alert alert-error mt-4">
        Could not reach the CKB node: {inspect(@error)}
      </div>

      <.form :if={@wallet} for={@create_form} phx-submit="create_offer" class="mt-6 flex flex-wrap items-end gap-2">
        <div>
          <label class="block text-xs opacity-70">Recipient hash (0x + 64 hex)</label>
          <input type="text" name="recipient_hash" class="input input-bordered input-sm" placeholder="0x0707...0707" />
        </div>
        <div>
          <label class="block text-xs opacity-70">Amount (KES minor units)</label>
          <input type="text" name="amount" class="input input-bordered input-sm" placeholder="25000" />
        </div>
        <.button type="submit" disabled={@busy == :create}>
          {if @busy == :create, do: "Creating…", else: "Create offer"}
        </.button>
      </.form>

      <div :if={@error == nil and @offers == []} class="mt-8 text-center opacity-60">
        No open offers right now.
      </div>

      <.table :if={@offers != []} id="offers" rows={@offers}>
        <:col :let={offer} label="Status">
          <span class={["badge", offer.status == :open && "badge-success", offer.status == :reserved && "badge-warning"]}>
            {offer.status}
          </span>
        </:col>
        <:col :let={offer} label="Amount (KES)">{format_amount(offer.amount)}</:col>
        <:col :let={offer} label="CKB locked">{format_capacity(offer.capacity_shannon)}</:col>
        <:col :let={offer} label="Recipient (hashed)">{short_hash(offer.recipient_hash)}</:col>
        <:col :let={offer} label="Cell">{short_hash(offer.out_point["tx_hash"])}:{offer.out_point["index"]}</:col>
        <:col :let={offer} label="Action">
          <.button
            :if={@wallet && offer.status == :open}
            phx-click="reserve_offer"
            phx-value-tx_hash={offer.out_point["tx_hash"]}
            phx-value-index={offer.out_point["index"]}
            disabled={@busy == :reserve}
          >
            {if @busy == :reserve, do: "Reserving…", else: "Reserve"}
          </.button>
          <.button
            :if={@wallet && offer.status == :reserved && offer.reserved_by_lock_hash == @wallet.lock_hash}
            phx-click="claim_offer"
            phx-value-tx_hash={offer.out_point["tx_hash"]}
            phx-value-index={offer.out_point["index"]}
            disabled={@busy == :claim}
          >
            {if @busy == :claim, do: "Claiming…", else: "Claim"}
          </.button>
        </:col>
      </.table>
    </div>
    """
  end

  defp format_amount(minor_units), do: :erlang.float_to_binary(minor_units / 100, decimals: 2)
  defp format_capacity(shannon), do: :erlang.float_to_binary(shannon / 100_000_000, decimals: 2) <> " CKB"

  defp short_hash("0x" <> hex), do: "0x" <> String.slice(hex, 0, 8) <> "…"
  defp short_hash(other), do: other
end
