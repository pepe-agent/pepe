defmodule Pepe.Config.Writer do
  @moduledoc """
  Serializes every config write through one process.

  The config is a plain JSON file, and each mutation is a `load |> modify |> save`. Run
  concurrently (a running agent authorizing a tool, a cron resetting a budget, the dashboard
  saving an edit) two of those can each load the same state, change different slices, and have the
  last save silently drop the other's change - a lost update. Funnelling every write through this
  single GenServer makes them serial, so each one sees the previous one's result.

  `Pepe.Config.update/1` is the public entry; nothing should write the file any other way.

  Every write is also journaled (`Pepe.Config.Journal`) with its source and which top-level
  keys changed - see that module. Source tagging works the same everywhere, from
  `Journal.source()` read in the calling process either way. External-write *detection*
  is the one part that only works along the real GenServer path, where state can track "the
  stamp right after my own last write" to notice a write this process didn't make; the inline
  fallback (no writer process up, or a nested call already inside one) has no persistent state
  to compare against and always reports `external?: false`, same as a single `mix pepe`
  one-shot process has no earlier write of its own to compare against anyway.
  """
  use GenServer

  alias Pepe.Config
  alias Pepe.Config.Journal

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Run `load |> fun |> save` serialized against every other writer. Falls back to running inline
  when the writer process isn't up (a `mix pepe` one-shot that never started the app - a single
  process with no concurrency to serialize), and also when already executing inside the writer
  (a nested `update` would otherwise deadlock on itself).
  """
  @spec update((map() -> map())) :: map()
  def update(fun) when is_function(fun, 1) do
    case Process.whereis(__MODULE__) do
      nil -> do_update(fun, Journal.source(), false)
      pid when pid == self() -> do_update(fun, Journal.source(), false)
      _pid -> GenServer.call(__MODULE__, {:update, fun, Journal.source()}, :infinity)
    end
  end

  @doc """
  Like `update/1`, but `fun` can refuse the write: it gets the freshly loaded config and
  returns `{:ok, new_config}` to save it or `{:error, reason}` to leave the file untouched.
  Because `fun` runs serialized against every other writer and its precondition check reads
  the config passed *into* it (not one fetched earlier by the caller), this is a real
  compare-and-swap: two concurrent callers racing to claim the same thing can't both win, with
  no extra lock. The rule that makes that true: a caller must never read a value with
  `Pepe.Config.get_.../1` and then write it back in a later, separate call: check and write
  have to happen inside the same `fun`.
  """
  @spec update_cas((map() -> {:ok, map()} | {:error, term()})) :: {:ok, map()} | {:error, term()}
  def update_cas(fun) when is_function(fun, 1) do
    case Process.whereis(__MODULE__) do
      nil -> do_update_cas(fun, Journal.source(), false)
      pid when pid == self() -> do_update_cas(fun, Journal.source(), false)
      _pid -> GenServer.call(__MODULE__, {:update_cas, fun, Journal.source()}, :infinity)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{last_stamp: nil, last_path: nil}}

  @impl true
  def handle_call({:update, fun, source}, _from, state) do
    external? = external_write?(state)
    result = do_update(fun, source, external?)
    {:reply, result, %{state | last_stamp: Config.file_stamp(), last_path: Config.path()}}
  end

  @impl true
  def handle_call({:update_cas, fun, source}, _from, state) do
    external? = external_write?(state)
    result = do_update_cas(fun, source, external?)
    {:reply, result, %{state | last_stamp: Config.file_stamp(), last_path: Config.path()}}
  end

  # `:absent` (no file yet, e.g. first-ever write) never counts as "external" - there is
  # nothing for anyone else to have changed. `nil` (this process has never written yet, or
  # PEPE_HOME just moved to a path this state has no stamp for - tests routinely swap it
  # per-test) is the same: nothing comparable to check against.
  defp external_write?(%{last_stamp: nil}), do: false

  defp external_write?(%{last_path: last_path, last_stamp: stamp}) do
    last_path == Config.path() and Config.file_stamp() not in [stamp, :absent]
  end

  defp do_update(fun, source, external?) do
    old = Config.load()
    new = fun.(old)
    saved = Config.save(new)
    Journal.record(source, old, saved, external?: external?)
    saved
  end

  defp do_update_cas(fun, source, external?) do
    old = Config.load()

    case fun.(old) do
      {:ok, new_config} ->
        saved = Config.save(new_config)
        Journal.record(source, old, saved, external?: external?)
        {:ok, saved}

      {:error, _} = err ->
        err
    end
  end
end
