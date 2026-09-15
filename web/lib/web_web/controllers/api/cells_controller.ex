defmodule WebWeb.Api.CellsController do
  @moduledoc """
  A thin proxy for `get_cells` on the CKB node's Indexer, scoped to lock
  scripts -- what a connected wallet's own JS needs to find its funding
  cells to build a transaction. Same "never touches a key" role as every
  other module in Web.Ckb: this just forwards a read.
  """

  use WebWeb, :controller

  alias Web.Ckb.Rpc

  @doc """
  GET /api/cells?code_hash=0x..&hash_type=type&args=0x..
  -> the raw get_cells response (objects: [...], last_cursor: ...)
  """
  def index(conn, %{"code_hash" => code_hash, "hash_type" => hash_type, "args" => args}) do
    search_key = %{"script" => %{"code_hash" => code_hash, "hash_type" => hash_type, "args" => args}, "script_type" => "lock"}

    case Rpc.call("get_cells", [search_key, "asc", "0x14"]) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "expected code_hash, hash_type, args query params"})
  end
end
