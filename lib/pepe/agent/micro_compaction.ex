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
  nothing is lost or corrupted. That same "safe to lose" property is what makes TTL-pruning
  entries fine too: a session abandoned mid-conversation, or one whose process died without
  a clean `clear/1`, would otherwise sit in this table forever. Pruned on a periodic sweep
  (`prune/0`), same shape as the Telegram gateway's own `prune_sent/0` for its sent-message
  cache - an entry not `put/3`-refreshed within `@ttl` is dropped.
  """

  use GenServer

  @table __MODULE__
  @ttl 7 * 24 * 60 * 60
  @sweep_interval 60 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @doc "A session's running summary and how many exchanges it covers, or `nil` if none yet."
  @spec get(String.t()) :: {String.t(), non_neg_integer()} | nil
  def get(session_key) do
    ensure_table()

    case :ets.lookup(@table, session_key) do
      [{_, summary, covered, _touched_at}] -> {summary, covered}
      [] -> nil
    end
  end

  @doc "Record a session's updated running summary and how many exchanges it now covers."
  @spec put(String.t(), String.t(), non_neg_integer()) :: :ok
  def put(session_key, summary, covered) do
    ensure_table()
    :ets.insert(@table, {session_key, summary, covered, System.system_time(:second)})
    :ok
  end

  @doc "Forget a session's running summary - a manual /compact just replaced the real thing."
  @spec clear(String.t()) :: :ok
  def clear(session_key) do
    ensure_table()
    :ets.delete(@table, session_key)
    :ok
  end

  @doc "Drop entries not refreshed via `put/3` in the last #{@ttl} seconds. Exposed for tests."
  @spec prune() :: :ok
  def prune do
    if :ets.whereis(@table) != :undefined do
      cutoff = System.system_time(:second) - @ttl
      :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end

    :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    prune()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end
end
