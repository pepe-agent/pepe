defmodule Pepe.Agent.MicroCompaction do
  @moduledoc """
  Cross-turn memory for micro-compaction: the running summary a session has folded so far,
  and how many of its middle "exchanges" (see `Pepe.Agent.Compaction.exchanges/1`) it already
  covers - keyed by session, so two different conversations never share one running summary.

  Kept OUTSIDE the persisted message list on purpose: folding it into `messages` itself would
  break the length-based "this turn's new messages" recovery `Pepe.Agent.Session.spawn_run`
  depends on (see the `to_send` vs `messages` split in `Pepe.Agent.Runtime`'s `loop/7`).

  In-memory (ETS `:set`) - a restart just means the next turn's fold starts fresh from
  `covered: 0`, which is safe: the affected turn pays what ordinary compaction always paid,
  nothing is lost or corrupted.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "A session's running summary and how many exchanges it covers, or `nil` if none yet."
  @spec get(String.t()) :: {String.t(), non_neg_integer()} | nil
  def get(session_key) do
    ensure_table()

    case :ets.lookup(@table, session_key) do
      [{_, summary, covered}] -> {summary, covered}
      [] -> nil
    end
  end

  @doc "Record a session's updated running summary and how many exchanges it now covers."
  @spec put(String.t(), String.t(), non_neg_integer()) :: :ok
  def put(session_key, summary, covered) do
    ensure_table()
    :ets.insert(@table, {session_key, summary, covered})
    :ok
  end

  @doc "Forget a session's running summary - a manual /compact just replaced the real thing."
  @spec clear(String.t()) :: :ok
  def clear(session_key) do
    ensure_table()
    :ets.delete(@table, session_key)
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end
end
