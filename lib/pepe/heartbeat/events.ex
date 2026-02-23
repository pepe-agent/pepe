defmodule Pepe.Heartbeat.Events do
  @moduledoc """
  An ephemeral, per-session **system events** queue - the payload channel a
  heartbeat pulse reads from.

  Any subsystem can drop a short note here (a backgrounded command finished, a
  webhook fired, a sub-agent completed) without knowing anything about heartbeats;
  the next pulse for that session picks them up and decides whether they're worth
  surfacing. Bounded ring (default 20) per key, in-memory only (an ETS table - lost
  on restart by design, these are transient nudges, not durable data).
  """

  use GenServer

  @table __MODULE__
  @max_per_key 20

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Queue a short note for `session_key`'s next heartbeat pulse."
  @spec push(String.t(), String.t()) :: :ok
  def push(session_key, text) when is_binary(session_key) and is_binary(text) do
    ensure_table()
    now = System.system_time(:second)
    :ets.insert(@table, {session_key, now, text})
    trim(session_key)
    :ok
  end

  @doc "Take (and clear) all pending events for `session_key`, oldest first."
  @spec take(String.t()) :: [String.t()]
  def take(session_key) do
    ensure_table()

    @table
    |> :ets.take(session_key)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 2))
  end

  @doc "Peek without clearing - how many events are pending."
  @spec count(String.t()) :: non_neg_integer()
  def count(session_key) do
    ensure_table()
    :ets.select_count(@table, [{{session_key, :_, :_}, [], [true]}])
  end

  defp trim(session_key) do
    entries = :ets.match_object(@table, {session_key, :_, :_})

    if length(entries) > @max_per_key do
      entries
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(length(entries) - @max_per_key)
      |> Enum.each(&:ets.delete_object(@table, &1))
    end
  end

  # The table owner (this GenServer) is started under the supervision tree, but
  # helpers may be called before it's up in tests - create on demand, idempotent.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    end
  end
end
