defmodule Pepe.Webhooks.Dedup do
  @moduledoc """
  Remembers which inbound messages a connection has already taken, for a few minutes.

  A platform that does not get its `200` quickly enough sends the same event again, and one
  that is retrying after its own outage can send a batch twice; Meta does both. Without a
  memory, the second copy of a voice note is downloaded, transcribed, answered and paid for
  a second time, and the person receives the same reply twice.

  The key is the connection plus the message's own id (`:id`, which every provider puts on
  what it parses), so two connections never shadow each other and a message with no id is
  simply never deduplicated. Entries expire after 10 minutes, which is far longer than any
  retry schedule and short enough that the table stays as small as recent traffic.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.minutes(10)
  @sweep_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Whether `id` was already seen on connection `slug`. Marks it seen as a side effect, so the
  first call for an id answers `false` and every later one answers `true`. A missing id is
  never a duplicate.
  """
  @spec seen?(String.t() | nil, term()) :: boolean()
  def seen?(slug, id) when is_binary(id) and id != "" do
    if :ets.whereis(@table) == :undefined do
      false
    else
      # Scoped to this instance's config home: one install has exactly one, so it changes
      # nothing there, and it keeps two instances in one VM (a test suite is the real case)
      # from sharing a memory they have no business sharing.
      not :ets.insert_new(@table, {{Pepe.Config.home(), slug, id}, System.monotonic_time(:millisecond)})
    end
  end

  def seen?(_slug, _id), do: false

  @doc false
  # Forget everything: for a test that feeds the same message id to a fresh connection.
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
