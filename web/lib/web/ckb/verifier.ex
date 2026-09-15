defmodule Web.Ckb.Verifier do
  @moduledoc """
  Phoenix's OWN role in this MVP as a stand-in for Ken's real, separate
  off-chain TLSNotary Verifier service: holds one secp256k1 private key
  server-side and produces the two kinds of attestation mpesa-escrow's
  and offer-guard's own contracts expect --

    - an OWNERSHIP proof ("this address controls the M-Pesa number
      hashed here"), read by offer-guard at MINT time, and
    - a CLAIM signature ("this M-Pesa transaction really paid this
      recipient this amount"), read by mpesa-escrow at CLAIM time.

  In the real system, producing that second attestation honestly
  requires a genuine TLSNotary MPC-TLS proof of the buyer's own M-Pesa
  session (see the Bitshada plan's protocol-pivot section) -- this
  module signs whatever it's told is true. That's an honest, deliberate
  MVP simplification for exercising the UI and the contracts end to end,
  not a security property anything should rely on; swapping in the real
  Verifier later only touches this one module; nothing else needs
  to change.

  Uses the exact SECP256K1ETH scheme mpesa-escrow's own
  `recover_eth_address` implements: secp256k1 with Keccak256 hashing,
  `r || s || v` (v = raw recovery id + 27, matching Solidity's
  `ecrecover`) -- confirmed byte-for-byte compatible with the Rust
  implementation via a cross-check during development (same private key,
  same message, same resulting address and recovery id).
  """

  @ownership_domain_tag 0x01

  defp private_key! do
    Application.fetch_env!(:web, :ckb)
    |> Keyword.fetch!(:verifier_private_key)
    |> String.trim_leading("0x")
    |> Base.decode16!(case: :mixed)
  end

  @doc "This Verifier's own Ethereum-style address, as 0x-prefixed hex."
  def address_hex do
    "0x" <> Base.encode16(address(), case: :lower)
  end

  defp address do
    {:ok, pubkey} = ExSecp256k1.create_public_key(private_key!())
    <<4, xy::binary>> = pubkey
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(xy)
    address
  end

  @doc """
  Signs `domain_tag(0x01) || recipient_hash` (33 bytes) -- offer-guard's
  own ownership-proof message. `recipient_hash` must be exactly 32 bytes.
  Returns the 65-byte signature.
  """
  def sign_ownership(<<recipient_hash::binary-size(32)>>) do
    sign(<<@ownership_domain_tag, recipient_hash::binary>>)
  end

  @doc """
  Signs `tx_id_hash || recipient_hash || amount` (72 bytes) -- mpesa-
  escrow's own claim message. `tx_id_seed` is any bytes uniquely
  identifying the underlying payment (a real TLSNotary-verified M-Pesa
  transaction reference, in the real system); this hashes it down to the
  32-byte tx_id_hash the contract's own nullifier registry actually
  stores. Returns `{tx_id_hash, signature}`.
  """
  def sign_claim(tx_id_seed, <<recipient_hash::binary-size(32)>>, amount) when is_integer(amount) do
    tx_id_hash = ExKeccak.hash_256(tx_id_seed)
    message = tx_id_hash <> recipient_hash <> <<amount::64-little-signed>>
    {tx_id_hash, sign(message)}
  end

  defp sign(message) do
    digest = ExKeccak.hash_256(message)
    {:ok, {compact_sig, recovery_id}} = ExSecp256k1.sign_compact(digest, private_key!())
    compact_sig <> <<recovery_id + 27>>
  end
end
