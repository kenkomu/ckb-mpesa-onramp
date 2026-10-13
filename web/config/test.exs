import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :web, WebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "RVLVQlCU/OgcxqwxXjKzgsMstY05ZAfELfMle5BMolaBOCrvjG9q9PAEnSoePln2",
  server: false

# In test we don't send emails
config :web, Web.Mailer, adapter: Swoosh.Adapters.Test

# Web.Ckb.Offers.list/0 (and anything else reading :web, :ckb) needs this
# key present or it raises via Application.fetch_env! before ever making
# a request -- the actual RPC call then fails fast against an unreachable
# port, which Web.Ckb.Rpc.call/2 already turns into a graceful
# {:error, reason} rather than a crash, exercising the same
# node-unreachable degraded path a real outage would hit.
config :web, :ckb,
  rpc_url: "http://127.0.0.1:1",
  sighash_code_hash: "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8",
  sighash_dep_group: %{tx_hash: "0xc05f08a40fc9879abb49b5a2c32a1e8bc6fa6ce33ed22d0f96bc405b2e267b70", index: 0},
  mpesa_escrow: %{
    code_hash: "0x74e8b52b2043efe2386a5f838a0a0ce44d0d087025e95a575eb40ba38b54e0f9",
    hash_type: "data1",
    cell_dep: %{tx_hash: "0x7d39c6d620218d7725159dcf203ef313d261cd1d10dd195df5c406ee273311be", index: 1}
  },
  claims_registry: %{
    code_hash: "0x5cfd31a4a0775052dd45b85637cabd9086b5f7f5d257227153b583d72f3c1000",
    hash_type: "data1",
    cell_dep: %{tx_hash: "0x7d39c6d620218d7725159dcf203ef313d261cd1d10dd195df5c406ee273311be", index: 0},
    type_hash: "0x3e8ab4b40421d56337f3204b0fb0fa2e96f9bf9bc322e3142e5e4d5778b694c5",
    type_args: "0x9d95b002b5c5c6c0910522c302bef36d0a3183208f28521c4a0f8a3bf581839c",
    genesis_out_point: %{tx_hash: "0x8a3e189a89df7ac36fc4aa310573961a544e3d38177b2f4c458b7b519f158c81", index: 0}
  },
  offer_guard: %{
    code_hash: "0x13c3c2b25bda33139e4d0ba52868b478d98d47c166d979e18898a3b8cfa786ba",
    hash_type: "data1",
    cell_dep: %{tx_hash: "0x7d39c6d620218d7725159dcf203ef313d261cd1d10dd195df5c406ee273311be", index: 2}
  },
  always_success: %{
    code_hash: "0xfd5c9693329386bf61812189788840c4438240b2ec536385a51e473c48727d1a",
    hash_type: "data1",
    cell_dep: %{tx_hash: "0x9069c933d8d72320412fea8bc5adbb57d981f8a47740077faff2a6070fbccb39", index: 0}
  }

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
