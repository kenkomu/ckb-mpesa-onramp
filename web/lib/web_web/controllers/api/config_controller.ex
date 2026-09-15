defmodule WebWeb.Api.ConfigController do
  @moduledoc """
  Everything a client (the web UI's own CCC-based JS, or a mobile app)
  needs to build mpesa-escrow/claims-registry/offer-guard transactions
  itself -- contract identities, cell_deps, and the trusted Verifier's
  own address. No secrets: the Verifier's private key never leaves
  `Web.Ckb.Verifier`.
  """

  use WebWeb, :controller

  def show(conn, _params) do
    ckb = Application.fetch_env!(:web, :ckb)

    json(conn, %{
      rpc_url: ckb[:rpc_url],
      sighash_code_hash: ckb[:sighash_code_hash],
      sighash_dep_group: ckb[:sighash_dep_group],
      mpesa_escrow: ckb[:mpesa_escrow],
      claims_registry: ckb[:claims_registry],
      offer_guard: ckb[:offer_guard],
      always_success: ckb[:always_success],
      verifier_address: Web.Ckb.Verifier.address_hex()
    })
  end
end
