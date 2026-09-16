import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :web, WebWeb.Endpoint, server: true
end

config :web, WebWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Set CKB_NETWORK=testnet to point this app at the real CKB Pudge
# testnet deployment instead of the local devnet dev.exs configures by
# default. Every value below comes straight from a real, verified
# testnet deployment (see devnet-ops/testnet_data/*.json) -- code_hash
# values are identical to devnet's own (same compiled binaries, and
# code_hash is purely a function of the binary bytes), only the
# cell_dep outpoints and the registry's own Type ID identity differ,
# since those are tied to which chain actually holds the deploying
# transactions.
if System.get_env("CKB_NETWORK") == "testnet" do
  config :web, :ckb,
    rpc_url: "https://testnet.ckb.dev/",
    sighash_code_hash: "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8",
    sighash_dep_group: %{tx_hash: "0xf8de3bb47d055cdf460d93a2a6e1b05f7432f9777c8c474abf4eec1d4aee5d37", index: 0},
    mpesa_escrow: %{
      code_hash: "0x74e8b52b2043efe2386a5f838a0a0ce44d0d087025e95a575eb40ba38b54e0f9",
      hash_type: "data1",
      cell_dep: %{tx_hash: "0xa5a85f5cc3a1977d8e244e01681312a7c62d7a9b4c09eafa8d207a81a75083c2", index: 1}
    },
    claims_registry: %{
      code_hash: "0x5cfd31a4a0775052dd45b85637cabd9086b5f7f5d257227153b583d72f3c1000",
      hash_type: "data1",
      cell_dep: %{tx_hash: "0xa5a85f5cc3a1977d8e244e01681312a7c62d7a9b4c09eafa8d207a81a75083c2", index: 0},
      type_hash: "0x2326d50a69f78d2abb8d097a6e95c90af12a30050c05e8b659c195e242d65341",
      type_args: "0x674daf2952fd3313fa0af28de346d9fc52ff865db47473af4e4f0e17dfdc783b",
      genesis_out_point: %{tx_hash: "0x84f46628f263e199dcc4eb726670bb5fbb8e8dc1272ae726cfad15cd45eecf3f", index: 0}
    },
    offer_guard: %{
      code_hash: "0x13c3c2b25bda33139e4d0ba52868b478d98d47c166d979e18898a3b8cfa786ba",
      hash_type: "data1",
      cell_dep: %{tx_hash: "0xa5a85f5cc3a1977d8e244e01681312a7c62d7a9b4c09eafa8d207a81a75083c2", index: 2}
    },
    always_success: %{
      code_hash: "0xfd5c9693329386bf61812189788840c4438240b2ec536385a51e473c48727d1a",
      hash_type: "data1",
      cell_dep: %{tx_hash: "0x7a741a9f7c6a6fa0a5ae22e102cd59f0b91189785ad61efd98396e901a7dd625", index: 0}
    },
    verifier_private_key:
      System.get_env(
        "BITSHADA_VERIFIER_PRIVATE_KEY",
        "0xf772d0917cd21824b6259816aa2da2a9675e7ff25b8a5e41703c34cb6d05a30e"
      )
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :web, WebWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/web_web/router\.ex$"E,
        ~r"lib/web_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :web, WebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :web, WebWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :web, WebWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :web, Web.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
