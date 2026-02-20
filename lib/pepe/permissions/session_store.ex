defmodule Pepe.Permissions.SessionStore do
  @moduledoc """
  In-memory, per-VM store of session-scoped tool approvals (the `:session` grant).

  Backed by a public named ETS table owned by this process for the node's lifetime.
  Being in RAM only is the point: a `:session` grant is forgotten when the session
  is reset (`/new` → `clear/1`) and when the node restarts — unlike an `:always`
  grant, which is persisted on the agent in `config.json`.
  """

  use GenServer

  @table :pepe_session_approvals

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Grant `tool` for `session_key` for the rest of this session."
  def allow(session_key, tool) do
    ensure_table()
    :ets.insert(@table, {{session_key, tool}})
    :ok
  end

  @doc "Whether `tool` is approved for `session_key`."
  def member?(session_key, tool) do
    ensure_table()
    :ets.member(@table, {session_key, tool})
  end

  @doc "Forget every grant for `session_key` (called on `/new`)."
  def clear(session_key) do
    ensure_table()
    :ets.match_delete(@table, {{session_key, :_}})
    :ok
  end

  @impl true
  def init(:ok) do
    ensure_table()
    {:ok, %{}}
  end

  # Create the table if it isn't there yet — tolerates being called before the
  # GenServer has started (e.g. from a fast CLI path).
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
