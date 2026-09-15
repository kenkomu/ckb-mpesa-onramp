defmodule WebWeb.Api.TxController do
  @moduledoc """
  Relays an already-signed transaction to the CKB node -- Phoenix's own
  "relay, not custodian" role (see Web.Ckb.Rpc's own moduledoc): this
  never sees a private key, it just forwards bytes the browser already
  signed. Also sidesteps the browser having to call the CKB RPC directly
  (which the node doesn't expose CORS headers for).
  """

  use WebWeb, :controller

  alias Web.Ckb.Rpc

  def send(conn, %{"transaction" => transaction}) do
    case Rpc.call("send_transaction", [transaction, "passthrough"]) do
      {:ok, tx_hash} -> json(conn, %{tx_hash: tx_hash})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end
end
