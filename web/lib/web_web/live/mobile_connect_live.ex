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
  """

  use WebWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, wallet: nil, wallet_error: nil)}
  end

  def handle_event("wallet_ready", %{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb}, socket) do
    wallet = %{address: address, lock_hash: lock_hash, balance_ckb: balance_ckb}

    deep_link =
      "bitshada://wallet-connected?" <>
        URI.encode_query(%{"address" => address, "lockHash" => lock_hash, "balanceCkb" => balance_ckb})

    {:noreply, socket |> assign(wallet: wallet) |> push_event("mobile_deep_link", %{url: deep_link})}
  end

  def handle_event("wallet_error", %{"message" => message}, socket) do
    {:noreply, assign(socket, wallet_error: message)}
  end

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="flex flex-col items-center justify-center min-h-[70vh] gap-4 text-center px-6">
      <div class="font-mono text-xs uppercase tracking-widest text-primary font-semibold">
        Bitshada &middot; Wallet
      </div>

      <div :if={@wallet == nil and @wallet_error == nil} class="flex flex-col items-center gap-3">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <p class="text-base-content/60">Connecting your wallet...</p>
      </div>

      <div :if={@wallet} class="flex flex-col items-center gap-2">
        <.icon name="hero-check-circle" class="size-10 text-success" />
        <p class="font-semibold">Wallet connected</p>
        <p class="font-mono text-xs text-base-content/60 break-all max-w-xs">{@wallet.address}</p>
        <p class="text-sm text-base-content/70">Returning to the app...</p>
      </div>

      <div :if={@wallet_error} class="flex flex-col items-center gap-2">
        <.icon name="hero-exclamation-triangle" class="size-10 text-error" />
        <p class="text-error text-sm">{@wallet_error}</p>
      </div>
    </div>
    """
  end
end
