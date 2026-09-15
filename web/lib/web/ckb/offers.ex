defmodule Web.Ckb.Offers do
  @moduledoc """
  Reads mpesa-escrow cells straight off the configured CKB node and
  decodes them into plain offer structs for the LiveView to render.

  Escrow cell shape (see contract/contracts/mpesa-escrow/src/main.rs):

    lock.args (124 bytes) = witness_address[20] || recipient_hash[32] ||
      amount[8 LE] || registry_type_hash[32] || offer_guard_type_hash[32]

    data = "" (open) or reserved_by_lock_hash[32] (reserved) -- see check
    4's own doc comment for why an escrow cell's DATA, not its args,
    carries this: args are fixed forever at mint time, but reservation
    state has to change without touching the offer's own identity.

  This module never decodes a CLAIMED escrow: once claimed, the cell no
  longer carries the mpesa-escrow lock at all (the payout output moves to
  the buyer's own lock), so it simply stops showing up in `list/0` -- the
  chain itself is the source of truth for "still open," not a flag this
  code has to maintain.
  """

  alias Web.Ckb.Rpc

  defstruct [
    :out_point,
    :capacity_shannon,
    :witness_address,
    :recipient_hash,
    :amount,
    :registry_type_hash,
    :offer_guard_type_hash,
    :status,
    :reserved_by_lock_hash
  ]

  @args_len 124
  @reservation_len 32

  @doc """
  Lists every live mpesa-escrow cell on the configured node, regardless of
  who created it or its reservation state. Returns `{:ok, [%__MODULE__{}]}`
  or `{:error, reason}` -- callers decide how to render a node-unreachable
  state, this module never raises for it.
  """
  def list do
    config = Application.fetch_env!(:web, :ckb)

    search_key = %{
      "script" => %{
        "code_hash" => Keyword.fetch!(config, :mpesa_escrow_code_hash),
        "hash_type" => Keyword.fetch!(config, :mpesa_escrow_hash_type),
        # Empty args + prefix mode matches every mpesa-escrow cell
        # regardless of its specific witness_address/recipient_hash/
        # amount/registry/guard combination -- this is a marketplace
        # listing, not a lookup for one specific offer.
        "args" => "0x"
      },
      "script_type" => "lock",
      "script_search_mode" => "prefix"
    }

    with {:ok, %{"objects" => objects}} <- Rpc.call("get_cells", [search_key, "asc", "0x64"]) do
      {:ok, Enum.map(objects, &decode_cell/1)}
    end
  end

  defp decode_cell(%{"out_point" => out_point, "output" => output, "output_data" => data_hex}) do
    args = output["lock"]["args"] |> unhex()
    data = unhex(data_hex)
    @args_len = byte_size(args)

    %__MODULE__{
      out_point: out_point,
      capacity_shannon: hex_to_int(output["capacity"]),
      witness_address: binary_part(args, 0, 20) |> tohex(),
      recipient_hash: binary_part(args, 20, 32) |> tohex(),
      amount: binary_part(args, 52, 8) |> :binary.decode_unsigned(:little),
      registry_type_hash: binary_part(args, 60, 32) |> tohex(),
      offer_guard_type_hash: binary_part(args, 92, 32) |> tohex()
    }
    |> put_status(data)
  end

  defp put_status(offer, <<>>), do: %{offer | status: :open}

  defp put_status(offer, <<reserved_by::binary-size(@reservation_len)>>) do
    %{offer | status: :reserved, reserved_by_lock_hash: tohex(reserved_by)}
  end

  defp put_status(offer, _other), do: %{offer | status: :unknown}

  defp unhex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp unhex(hex), do: Base.decode16!(hex, case: :mixed)

  defp tohex(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  defp hex_to_int("0x" <> hex), do: String.to_integer(hex, 16)
end
