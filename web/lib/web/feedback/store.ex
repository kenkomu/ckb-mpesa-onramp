defmodule Web.Feedback.Store do
  @moduledoc """
  Holds pilot-tester feedback submissions. This app deliberately has no
  Ecto/Postgres (see the grant plan's "indexer, not custodian" framing) --
  a GenServer that appends to a plain JSONL file is the lightest thing
  that still survives a `git pull` + service restart deploy cycle, since
  `priv/feedback/` is gitignored and untracked paths are never touched by
  `git pull --ff-only` (the same reasoning `priv/static/downloads/`
  already relies on for the pilot APK).

  Read via `ssh` + `cat`/`grep` on the VPS, not a web view -- there's no
  `list/0` here on purpose, keeping this to exactly what a 2-3 person
  pilot needs.
  """
  use GenServer

  @file_path Path.join(:code.priv_dir(:web), "feedback/submissions.jsonl")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Appends a feedback submission. `fields` is a plain map of form data."
  def submit(fields) when is_map(fields) do
    GenServer.call(__MODULE__, {:submit, fields})
  end

  @impl true
  def init(:ok) do
    File.mkdir_p!(Path.dirname(@file_path))
    {:ok, %{}}
  end

  @impl true
  def handle_call({:submit, fields}, _from, state) do
    entry = Map.put(fields, "submitted_at", DateTime.utc_now() |> DateTime.to_iso8601())
    line = Jason.encode!(entry) <> "\n"
    result = File.write(@file_path, line, [:append])
    {:reply, result, state}
  end
end
