defmodule WebWeb.MobileConnectLive do
  @moduledoc """
  The mobile app's wallet-connect handoff page: opened in the system
  browser (never an embedded WebView, so the real Chrome/whatever the
  user already trusts handles the actual key material) via
  `url_launcher`, per the project plan's documented pattern for
  platforms with no native CKB wallet SDK -- "hop out to a URL, come
  back via deep link."

  Reuses the exact same `Wallet` JS hook and `ckb.js` signer the web
  marketplace itself uses; this page's only job is to show the
  connected wallet and then redirect to `bitshada://wallet-connected`
  with the address/lockHash/balance as query params, which the Android
  app's intent filter (see mobile/android AndroidManifest.xml) catches.

  The app passes a random `state` param when it opens this page, echoed
  back verbatim in the redirect -- see WalletConnectService's own doc
  comment on `_newState` for why that matters: without it, a listener
  that's just subscribed can be handed a stale link the platform is
  still holding from an earlier launch, mistaking old data for this
  call's real result.
  """

  use WebWeb, :live_view

  def mount(params, _session, socket) do
    {:ok, assign(socket, wallet: nil, wallet_error: nil, state: params["state"])}
  end

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb}, socket) do
    wallet = %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb}

    deep_link =
      "bitshada://wallet-connected?" <>
        URI.encode_query(%{
          "address" => address,
          "lockHash" => lock_hash,
          "balanceCkb" => balance_ckb,
          "state" => socket.assigns.state
        })

    {:noreply, socket |> assign(wallet: wallet) |> push_event("mobile_deep_link", %{url: deep_link})}
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message)}
  end

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="flex flex-col items-center justify-center min-h-[70vh] gap-4 text-center px-6">
      <div class="card bg-base-200 border border-base-300 shadow-sm w-full max-w-xs">
        <div class="card-body items-center py-8">
          <WebWeb.Layouts.brand_mark class="size-10 mb-1" />
          <div class="font-mono text-xs uppercase tracking-widest text-primary font-semibold">
            Bitshada &middot; Wallet
          </div>

          <div :if={@wallet == nil and @wallet_error == nil} class="flex flex-col items-center gap-3 mt-2">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="text-base-content/60">Connecting your wallet...</p>
          </div>

          <div :if={@wallet} class="flex flex-col items-center gap-2 mt-2">
            <.icon name="hero-check-circle" class="size-10 text-success" />
            <p class="font-semibold">Wallet connected</p>
            <p class="font-mono text-xs text-base-content/60 break-all max-w-xs">{@wallet.address}</p>
            <p class="text-sm text-base-content/70">Returning to the app...</p>
          </div>

          <div :if={@wallet_error} class="flex flex-col items-center gap-2 mt-2">
            <.icon name="hero-exclamation-triangle" class="size-10 text-error" />
            <p class="text-error text-sm">{@wallet_error}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
