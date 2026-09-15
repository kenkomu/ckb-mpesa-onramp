defmodule WebWeb.Api.RegistryController do
  @moduledoc """
  The claims-registry cell's current live location -- see
  Web.Ckb.Registry's own moduledoc for why a client has to look this up
  fresh rather than caching it (every claim consumes and recreates it).
  """

  use WebWeb, :controller

  alias Web.Ckb.Registry

  def current(conn, _params) do
    case Registry.current() do
      {:ok, cell} -> json(conn, cell)
      {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
    end
  end
end
