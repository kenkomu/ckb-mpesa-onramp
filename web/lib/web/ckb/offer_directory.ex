defmodule Web.Ckb.OfferDirectory do
  @moduledoc """
  Off-chain lookup from an offer's on-chain `recipient_hash` to the
  seller's real M-Pesa number and wallet.

  The chain only stores the hash, so a buyer would have nobody to pay.
  This GenServer keeps `hash -> number` so the buyer who reserved an
  offer can be shown who to send the KES to. It never touches funds:
  the contract still releases CKB only against the hash it was minted
  with. Persisted to a gitignored JSONL file, same approach as
  `Web.Feedback.Store`.

  Pilot caveat: the number is only revealed in the UI to the wallet that
  reserved the offer, but that is a UI rule, not a cryptographic one.
  """
  use GenServer

  @file_path Path.join(:code.priv_dir(:web), "offers/directory.jsonl")

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Records the seller's number (and wallet lock hash, if known) for an offer hash."
  def register(recipient_hash, number, seller_lock_hash \\ nil) do
    GenServer.call(__MODULE__, {:register, recipient_hash, number, seller_lock_hash})
  end

  @doc "Returns `%{number: ..., seller_lock_hash: ...}` or nil."
  def lookup(recipient_hash), do: GenServer.call(__MODULE__, {:lookup, recipient_hash})

  @doc "SHA-256 of the number, 0x-hex -- identical to ckb.js's hashIdentifier."
  def hash(number), do: "0x" <> Base.encode16(:crypto.hash(:sha256, String.trim(number)), case: :lower)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Path.dirname(@file_path))
    {:ok, load()}
  end

  @impl true
  def handle_call({:register, hash, number, seller}, _from, state) do
    entry = %{"hash" => hash, "number" => number, "seller_lock_hash" => seller}
    result = File.write(@file_path, Jason.encode!(entry) <> "\n", [:append])
    {:reply, result, Map.put(state, hash, %{number: number, seller_lock_hash: seller})}
  end

  def handle_call({:lookup, hash}, _from, state), do: {:reply, Map.get(state, hash), state}

  defp load do
    case File.read(@file_path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case Jason.decode(line) do
            {:ok, %{"hash" => h, "number" => n} = e} ->
              Map.put(acc, h, %{number: n, seller_lock_hash: e["seller_lock_hash"]})

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end
end
