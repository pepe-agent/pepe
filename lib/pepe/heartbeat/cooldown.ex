defmodule Pepe.Heartbeat.Cooldown do
  @moduledoc """
  Anti-spam gate every heartbeat pulse must pass through - makes a runaway
  self-triggering loop mathematically impossible.

  Two independent guards, both keyed per session:

    * **Minimum spacing** - pulses closer together than `@min_spacing_ms` are
      deferred, regardless of why they were requested.
    * **Flood breaker** - if a key would fire ≥5 times within 60s, every further
      pulse for that key is deferred until the window clears.

  In-memory only (an ETS table of recent fire timestamps) - a restart naturally
  resets the guard, which is fine since there's nothing to protect across a restart.
  """

  use GenServer

  @table __MODULE__
  @min_spacing_ms 30_000
  @flood_window_ms 60_000
  @flood_max 5

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  May a pulse fire for `key` right now? If so, **records** the fire (so back-to-back
  calls correctly see it) and returns `:ok`. Otherwise returns `{:defer, reason}`.
  """
  @spec allow?(String.t()) :: :ok | {:defer, :min_spacing | :flood}
  def allow?(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    recent = @table |> :ets.lookup(key) |> Enum.map(&elem(&1, 1)) |> Enum.sort(:desc)

    cond do
      recent != [] and now - hd(recent) < @min_spacing_ms ->
        {:defer, :min_spacing}

      length(Enum.filter(recent, &(now - &1 < @flood_window_ms))) >= @flood_max ->
        {:defer, :flood}

      true ->
        :ets.insert(@table, {key, now})
        prune(key, now)
        :ok
    end
  end

  defp prune(key, now) do
    @table
    |> :ets.lookup(key)
    |> Enum.filter(&(now - elem(&1, 1) > @flood_window_ms))
    |> Enum.each(&:ets.delete_object(@table, &1))
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    end
  end
end
