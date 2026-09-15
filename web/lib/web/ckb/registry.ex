defmodule Web.Ckb.Registry do
  @moduledoc """
  Looks up the ONE live claims-registry cell by its Type Script identity
  (see check 1's own design: a single continuously-live cell, consumed
  and recreated by every claim, so its OutPoint changes each time -- a
  client building a CLAIM transaction has to look this up fresh, not
  cache it).
  """

  alias Web.Ckb.Rpc

  @doc """
  Returns `{:ok, %{out_point: .., capacity: .., data: ..}}` for the
  configured registry's current live cell, or `{:error, reason}`.
  """
  def current do
    registry = Application.fetch_env!(:web, :ckb) |> Keyword.fetch!(:claims_registry)

    # Exact match on the registry's own Type ID args -- there is, by
    # design, exactly one live cell with this identity at any time.
    # `script_type: "type"` tells the RPC to match against each cell's
    # TYPE script field (not its lock); the script itself (code_hash +
    # hash_type + args) is still the registry contract's own identity,
    # same as any other script lookup.
    search_key = %{
      "script" => %{"code_hash" => registry.code_hash, "hash_type" => registry.hash_type, "args" => registry.type_args},
      "script_type" => "type"
    }

    with {:ok, %{"objects" => [cell | _]}} <- Rpc.call("get_cells", [search_key, "asc", "0x1"]) do
      {:ok,
       %{
         out_point: cell["out_point"],
         capacity: cell["output"]["capacity"],
         lock: cell["output"]["lock"],
         data: cell["output_data"]
       }}
    else
      {:ok, %{"objects" => []}} -> {:error, :registry_not_found}
      other -> other
    end
  end
end
