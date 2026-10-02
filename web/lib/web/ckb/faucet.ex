defmodule Web.Ckb.Faucet do
  @moduledoc """
  Self-serve testnet CKB funding, replacing the "email Ken to get
  funded" flow -- the real scaling bottleneck for a pilot with more than
  a couple of testers.

  Deliberately shells out to the already-built, already-tested
  `devnet-ops/fund_lock_args` Rust binary rather than reimplementing
  CKB's `secp256k1_blake160_sighash_all` transaction signing in Elixir:
  this app's own crypto deps (`ex_secp256k1`/`ex_keccak`) only cover the
  *Ethereum-style* Keccak signing already used for OfferGuard
  attestations, and there's no blake2b or CKB molecule-serialization
  library here -- that would be new engineering, not reuse. The faucet
  transaction is signed entirely server-side by the faucet's own funded
  key, same shape as the Verifier's existing server-side OfferGuard
  signing (see `Web.VerifierController`) -- the tester's wallet never
  signs anything for this.

  Rate-limit state is in-memory only and intentionally lost on restart:
  losing a cooldown window occasionally is low-stakes for a small pilot,
  unlike feedback, which is durably persisted.
  """
  use GenServer
  require Logger

  @cooldown_seconds 24 * 60 * 60
  @amount_ckb "300"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Requests a faucet top-up for `lock_args` (a 0x-prefixed 20-byte
  blake160 hex string). Returns `{:ok, tx_hash}`, `{:error, :cooldown, seconds_remaining}`,
  or `{:error, reason}`.
  """
  def request(lock_args) when is_binary(lock_args) do
    GenServer.call(__MODULE__, {:request, lock_args}, 90_000)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:request, lock_args}, _from, state) do
    now = System.system_time(:second)

    case Map.get(state, lock_args) do
      last when is_integer(last) and now - last < @cooldown_seconds ->
        {:reply, {:error, :cooldown, @cooldown_seconds - (now - last)}, state}

      _ ->
        case run_fund_lock_args(lock_args) do
          {:ok, tx_hash} -> {:reply, {:ok, tx_hash}, Map.put(state, lock_args, now)}
          error -> {:reply, error, state}
        end
    end
  end

  defp run_fund_lock_args(lock_args) do
    config = Application.fetch_env!(:web, :faucet)
    bin = config[:binary_path]
    cwd = config[:devnet_ops_dir]

    env = [
      {"CKB_RPC_URL", config[:rpc_url]},
      {"CKB_KEY_FILE", "faucet_key.txt"},
      {"CKB_DATA_DIR", config[:data_dir]},
      {"CKB_SIGHASH_DEP_GROUP_TX_HASH", config[:sighash_dep_group_tx_hash]},
      {"CKB_SIGHASH_DEP_GROUP_INDEX", to_string(config[:sighash_dep_group_index])}
    ]

    case System.cmd(bin, [lock_args, @amount_ckb], cd: cwd, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        # fund_lock_args's own println: "Sent fund_lock_args tx: {tx_hash} (...)"
        case Regex.run(~r/Sent fund_lock_args tx: (0x[0-9a-f]+)/, output) do
          [_, hash] -> {:ok, hash}
          nil -> {:error, "faucet transaction sent but no tx hash found in output: #{output}"}
        end

      {output, code} ->
        Logger.error("faucet fund_lock_args failed (exit #{code}): #{output}")
        {:error, "faucet transaction failed -- try again shortly"}
    end
  end
end
