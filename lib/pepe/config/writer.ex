defmodule Pepe.Config.Writer do
  @moduledoc """
  Serializes every config write through one process.

  The config is a plain JSON file, and each mutation is a `load |> modify |> save`. Run
  concurrently (a running agent authorizing a tool, a cron resetting a budget, the dashboard
  saving an edit) two of those can each load the same state, change different slices, and have the
  last save silently drop the other's change - a lost update. Funnelling every write through this
  single GenServer makes them serial, so each one sees the previous one's result.

  `Pepe.Config.update/1` is the public entry; nothing should write the file any other way.
  """
  use GenServer

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
      nil -> do_update(fun)
      pid when pid == self() -> do_update(fun)
      _pid -> GenServer.call(__MODULE__, {:update, fun}, :infinity)
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
      nil -> do_update_cas(fun)
      pid when pid == self() -> do_update_cas(fun)
      _pid -> GenServer.call(__MODULE__, {:update_cas, fun}, :infinity)
    end
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:update, fun}, _from, state), do: {:reply, do_update(fun), state}

  @impl true
  def handle_call({:update_cas, fun}, _from, state), do: {:reply, do_update_cas(fun), state}

  defp do_update(fun), do: Pepe.Config.load() |> fun.() |> Pepe.Config.save()

  defp do_update_cas(fun) do
    case fun.(Pepe.Config.load()) do
      {:ok, new_config} -> {:ok, Pepe.Config.save(new_config)}
      {:error, _} = err -> err
    end
  end
end
