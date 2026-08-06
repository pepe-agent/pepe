defmodule Pepe.Agent.RunObservers.Health do
  @moduledoc """
  Cross-run circuit breaker for `Pepe.Agent.RunObserver` plugins: one that fails 3 times
  in a row stays disabled across every future run - not just for the run that tripped it -
  until manually reset (`reset/1`). A counter that only lived for one run would reset every
  turn and never actually disable a permanently broken observer, paying the cost of
  detecting the same failure forever.

  Backed by ETS, not `:persistent_term` (unlike `Pepe.Slots.Health`, which records rare
  events): a broken observer failing repeatedly is by definition a high-write path, and
  every `:persistent_term` write forces a full VM GC sweep.
  """
  use GenServer

  @table __MODULE__
  @limit 3

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Is `mod` currently disabled (3+ consecutive failures since its last success)?"
  def disabled?(mod) do
    case :ets.lookup(@table, mod) do
      [{^mod, count}] -> count >= @limit
      [] -> false
    end
  end

  @doc "Record a failed dispatch to `mod`. Returns true the instant it crosses the disable threshold."
  def record_failure(mod), do: :ets.update_counter(@table, mod, {2, 1}, {mod, 0}) == @limit

  @doc "Record a clean dispatch to `mod` - resets its failure streak."
  def record_success(mod), do: :ets.insert(@table, {mod, 0})

  @doc "Manually re-enable a disabled observer, e.g. after fixing and reinstalling it."
  def reset(mod), do: :ets.insert(@table, {mod, 0})
end
