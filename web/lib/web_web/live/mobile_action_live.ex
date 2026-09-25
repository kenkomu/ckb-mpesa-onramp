defmodule WebWeb.MobileActionLive do
  @moduledoc """
  The mobile app's transaction handoff page: opened in the system
  browser for exactly one create/reserve/claim action, identified by
  query params, e.g.

      /mobile/action?action=reserve&tx_hash=0x...&index=0x1
      /mobile/action?action=create&identifier=0712345678&amount=250
      /mobile/action?action=claim&tx_hash=0x...&index=0x1

  Runs that one action automatically via the same `Wallet` JS hook and
  `ckb.js` the web marketplace uses (so it's the exact same signing
  code, not a second implementation), then redirects to
  `bitshada://action-done?...` or `bitshada://action-error?...` --
  never both an action and someone browsing, unlike OffersLive.

  Echoes back the `state` query param the app passed when it opened
  this page -- see WalletConnectService's own `_newState` doc comment
  for why (guards against the app's deep-link listener picking up a
  stale link left over from an earlier launch instead of this call's
  real result).
  """

  use WebWeb, :live_view

  alias Web.Ckb.Offers

  def mount(params, _session, socket) do
    {:ok, assign(socket, params: params, wallet: nil, wallet_error: nil, status: :connecting, error: nil)}
  end

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb}, socket) do
    wallet = %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb}
    socket = assign(socket, wallet: wallet, wallet_error: nil)

    case socket.assigns.status do
      :connecting -> {:noreply, start_action(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message, status: :error, error: "Wallet unavailable: #{message}")}
  end

  def handle_event("tx_success", %{"action" => action, "tx_hash" => tx_hash}, socket) do
    deep_link =
      "bitshada://action-done?" <>
        URI.encode_query(%{"action" => action, "tx_hash" => tx_hash, "state" => socket.assigns.params["state"]})

    {:noreply, socket |> assign(status: :done) |> push_event("mobile_deep_link", %{url: deep_link})}
  end

  def handle_event("tx_error", %{"action" => action, "message" => message}, socket) do
    deep_link =
      "bitshada://action-error?" <>
        URI.encode_query(%{"action" => action, "message" => message, "state" => socket.assigns.params["state"]})

    {:noreply, socket |> assign(status: :error, error: message) |> push_event("mobile_deep_link", %{url: deep_link})}
  end

  defp start_action(socket) do
    case socket.assigns.params do
      %{"action" => "create", "identifier" => identifier, "amount" => amount_kes} ->
        with {:ok, identifier} <- Offers.validate_identifier(identifier),
             {:ok, minor_units} <- Offers.parse_kes(amount_kes) do
          socket
          |> assign(status: :running)
          |> push_event("run_create_offer", %{identifier: identifier, amount: minor_units})
        else
          _ -> assign(socket, status: :error, error: "Invalid create-offer parameters.")
        end

      %{"action" => "reserve", "tx_hash" => tx_hash, "index" => index} ->
        case Offers.find(tx_hash, index) do
          nil -> assign(socket, status: :error, error: "That offer isn't listed anymore.")
          offer -> socket |> assign(status: :running) |> push_event("run_reserve_offer", %{offer: Offers.to_json(offer)})
        end

      %{"action" => "claim", "tx_hash" => tx_hash, "index" => index} ->
        case Offers.find(tx_hash, index) do
          nil ->
            assign(socket, status: :error, error: "That offer isn't listed anymore.")

          offer ->
            tx_id_seed = "mobile-claim-#{System.system_time()}"

            socket
            |> assign(status: :running)
            |> push_event("run_claim_offer", %{offer: Offers.to_json(offer), tx_id_seed: tx_id_seed})
        end

      _ ->
        assign(socket, status: :error, error: "Missing or unknown action parameters.")
    end
  end

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="flex flex-col items-center justify-center min-h-[70vh] gap-4 text-center px-6">
      <div class="card bg-base-200 border border-base-300 shadow-sm w-full max-w-xs">
        <div class="card-body items-center py-8">
          <WebWeb.Layouts.brand_mark class="size-10 mb-1" />
          <div class="font-mono text-xs uppercase tracking-widest text-primary font-semibold">
            Bitshada
          </div>

          <div :if={@status in [:connecting, :running]} class="flex flex-col items-center gap-3 mt-2">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="text-base-content/60">
              {if @status == :connecting, do: "Connecting your wallet...", else: "Submitting to the chain..."}
            </p>
          </div>

          <div :if={@status == :done} class="flex flex-col items-center gap-2 mt-2">
            <.icon name="hero-check-circle" class="size-10 text-success" />
            <p class="font-semibold">Done</p>
            <p class="text-sm text-base-content/70">Returning to the app...</p>
          </div>

          <div :if={@status == :error} class="flex flex-col items-center gap-2 mt-2">
            <.icon name="hero-exclamation-triangle" class="size-10 text-error" />
            <p class="text-error text-sm max-w-xs">{@error}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
