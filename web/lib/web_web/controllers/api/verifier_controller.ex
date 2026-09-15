defmodule WebWeb.Api.VerifierController do
  @moduledoc """
  The two attestations `Web.Ckb.Verifier` produces, exposed over HTTP --
  see that module's own moduledoc for the honest caveat: this MVP signs
  whatever it's told, as a stand-in for a real TLSNotary Verifier. Every
  binary field here is 0x-prefixed hex in, 0x-prefixed hex out.
  """

  use WebWeb, :controller

  alias Web.Ckb.Verifier

  @doc """
  POST /api/verifier/ownership_signature
  body: {"recipient_hash": "0x" <> 64 hex chars}
  -> {"signature": "0x" <> 130 hex chars, "verifier_address": "0x..."}
  """
  def ownership_signature(conn, %{"recipient_hash" => recipient_hash_hex}) do
    with {:ok, recipient_hash} <- decode_hash32(recipient_hash_hex) do
      signature = Verifier.sign_ownership(recipient_hash)

      json(conn, %{
        signature: to_hex(signature),
        verifier_address: Verifier.address_hex()
      })
    else
      :error -> bad_request(conn, "recipient_hash must be 0x-prefixed 32-byte hex")
    end
  end

  @doc """
  POST /api/verifier/claim_signature
  body: {"tx_id_seed": "any string identifying the payment",
         "recipient_hash": "0x" <> 64 hex chars, "amount": integer}
  -> {"tx_id_hash": "0x...", "signature": "0x..."}
  """
  def claim_signature(conn, %{"tx_id_seed" => tx_id_seed, "recipient_hash" => recipient_hash_hex, "amount" => amount})
      when is_binary(tx_id_seed) and is_integer(amount) do
    with {:ok, recipient_hash} <- decode_hash32(recipient_hash_hex) do
      {tx_id_hash, signature} = Verifier.sign_claim(tx_id_seed, recipient_hash, amount)
      json(conn, %{tx_id_hash: to_hex(tx_id_hash), signature: to_hex(signature)})
    else
      :error -> bad_request(conn, "recipient_hash must be 0x-prefixed 32-byte hex")
    end
  end

  def claim_signature(conn, _params) do
    bad_request(conn, "expected tx_id_seed (string), recipient_hash (0x-hex), amount (integer)")
  end

  defp decode_hash32("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp decode_hash32(_), do: :error

  defp to_hex(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  defp bad_request(conn, message) do
    conn |> put_status(:bad_request) |> json(%{error: message})
  end
end
