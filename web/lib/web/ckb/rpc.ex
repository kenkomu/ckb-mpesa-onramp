defmodule Web.Ckb.Rpc do
  @moduledoc """
  A thin JSON-RPC client for a CKB node. Phoenix's own role in this
  architecture is an indexer/relay over CKB, not a system of record (see
  the Bitshada plan's "What Phoenix actually is" note) -- it never holds a
  private key and never signs anything, so every call here is a plain
  read (or, later, a `send_transaction` relay of an already-signed
  transaction built and signed entirely client-side). If Phoenix is down,
  the worst case is a degraded UI, never a fund-safety issue -- that
  guarantee comes only from the Lock Script itself.
  """

  @doc """
  Calls `method` with `params` against the configured CKB node and
  returns `{:ok, result}` or `{:error, reason}` -- never raises, so a
  LiveView mount can degrade to an empty/error state instead of crashing
  the whole page when the node is unreachable.
  """
  def call(method, params \\ []) do
    url = Application.fetch_env!(:web, :ckb) |> Keyword.fetch!(:rpc_url)

    body = %{"id" => 1, "jsonrpc" => "2.0", "method" => method, "params" => params}

    case Req.post(url, json: body, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status}} ->
        {:error, "unexpected HTTP status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
