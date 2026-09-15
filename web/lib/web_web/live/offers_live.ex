defmodule WebWeb.OffersLive do
  @moduledoc """
  The open-offers marketplace list -- Phoenix's own role here is exactly
  the "indexer, not custodian" one described in the Bitshada plan: this
  page reads real mpesa-escrow cells straight off the configured CKB
  node and renders them, but never touches a private key. Buying/
  creating an offer (the wallet-connect + signing flow) is a separate,
  not-yet-built piece -- this page proves the read side of the
  architecture against the real devnet first.
  """

  use WebWeb, :live_view

  alias Web.Ckb.Offers

  def mount(_params, _session, socket) do
    {:ok, load_offers(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_offers(socket)}
  end

  defp load_offers(socket) do
    case Offers.list() do
      {:ok, offers} -> assign(socket, offers: offers, error: nil)
      {:error, reason} -> assign(socket, offers: [], error: reason)
    end
  end

  def render(assigns) do
    ~H"""
    <.header>
      Open offers
      <:subtitle>Live mpesa-escrow cells read straight off the CKB devnet -- no database in between.</:subtitle>
      <:actions>
        <.button phx-click="refresh">Refresh</.button>
      </:actions>
    </.header>

    <div :if={@error} class="alert alert-error mt-4">
      Could not reach the CKB node: {inspect(@error)}
    </div>

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
    </.table>
    """
  end

  defp format_amount(minor_units), do: :erlang.float_to_binary(minor_units / 100, decimals: 2)
  defp format_capacity(shannon), do: :erlang.float_to_binary(shannon / 100_000_000, decimals: 2) <> " CKB"

  defp short_hash("0x" <> hex), do: "0x" <> String.slice(hex, 0, 8) <> "…"
  defp short_hash(other), do: other
end
