defmodule WebWeb.Api.OffersController do
  @moduledoc """
  The same read Web.Ckb.Offers backs the LiveView marketplace page with,
  as plain JSON -- the surface a mobile app (or any other client) reads
  the open-offers list from.
  """

  use WebWeb, :controller

  alias Web.Ckb.Offers

  def index(conn, _params) do
    case Offers.list() do
      {:ok, offers} ->
        json(conn, %{offers: Enum.map(offers, &offer_json/1)})

      {:error, reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
    end
  end

  defp offer_json(offer) do
    %{
      out_point: offer.out_point,
      capacity_shannon: offer.capacity_shannon,
      witness_address: offer.witness_address,
      recipient_hash: offer.recipient_hash,
      amount: offer.amount,
      registry_type_hash: offer.registry_type_hash,
      offer_guard_type_hash: offer.offer_guard_type_hash,
      status: offer.status,
      reserved_by_lock_hash: offer.reserved_by_lock_hash
    }
  end
end
