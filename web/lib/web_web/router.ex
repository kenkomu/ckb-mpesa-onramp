defmodule WebWeb.Router do
  use WebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WebWeb do
    pipe_through :browser

    live "/", OffersLive
    live "/offers", OffersLive

    # Mobile app handoff pages -- opened in the system browser via
    # url_launcher, never an embedded WebView, per the project plan's
    # "hop out to a URL, come back via deep link" wallet-connect
    # pattern. See each LiveView's own moduledoc.
    live "/mobile/connect", MobileConnectLive
    live "/mobile/action", MobileActionLive
  end

  # The JSON API surface: everything a mobile app (or the web UI's own
  # CCC-based JS) needs to build and submit mpesa-escrow transactions
  # itself. Read-only except send/2 (relays an already-signed tx) and the
  # verifier endpoints (produce an off-chain attestation signature, never
  # a chain-affecting action) -- see each controller's own moduledoc.
  scope "/api", WebWeb.Api do
    pipe_through :api

    get "/config", ConfigController, :show
    get "/offers", OffersController, :index
    get "/registry", RegistryController, :current
    get "/cells", CellsController, :index
    post "/tx/send", TxController, :send
    post "/verifier/ownership_signature", VerifierController, :ownership_signature
    post "/verifier/claim_signature", VerifierController, :claim_signature
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WebWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
