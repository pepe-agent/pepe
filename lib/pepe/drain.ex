defmodule Pepe.Drain do
  @moduledoc """
  The admission gate for a shutdown. `Pepe.Application.prep_stop/1` calls `start/0` first: from
  then on nothing new is admitted (an HTTP chat request, a webhook message, a Telegram poll, a
  cron tick all check `draining?/0`), while what was already running keeps going. Work that is
  mid-run registers with `enter/1` so `await/1` can wait for it to finish, instead of killing a
  conversation turn together with the VM.

  The flag is a `:persistent_term`, so checking it costs nothing on the hot path. Work is tracked
  by monitoring the process doing it, so a run that crashes is counted out on its own.
  """
  use GenServer

  @flag {__MODULE__, :draining}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Stop admitting new work. Idempotent."
  @spec start() :: :ok
  def start do
    :persistent_term.put(@flag, true)
    :ok
  end

  @doc "Admit work again (tests, and a drain that was called off)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@flag, false)
    :ok
  end

  @doc """
  Is a shutdown draining? When true, new work is refused. Only meaningful while the gate process
  runs: once it is gone (the application stopped, or a test that never started it) the flag left
  behind by an earlier shutdown is stale and nothing is refused.
  """
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@flag, false) and Process.whereis(__MODULE__) != nil

  @doc """
  Count `pid` as work in flight until it exits or `leave/1` is called with the returned token.
  Returns `nil` (and tracks nothing) when the gate is not running, so callers need no guard.
  """
  @spec enter(pid()) :: reference() | nil
  def enter(pid) when is_pid(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:enter, pid}), else: nil
  end

  @doc "End what `enter/1` started. A `nil` token is ignored."
  @spec leave(reference() | nil) :: :ok
  def leave(nil), do: :ok

  def leave(token) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:leave, token})
    :ok
  end

  @doc "How many pieces of work are in flight."
  @spec in_flight() :: non_neg_integer()
  def in_flight, do: if(Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :count), else: 0)

  @doc "Wait until nothing is in flight, up to `timeout` ms. `:ok`, or `{:timeout, still_running}`."
  @spec await(non_neg_integer()) :: :ok | {:timeout, non_neg_integer()}
  def await(timeout) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:await, timeout}, timeout + 5_000), else: :ok
  end

  # A fresh start admits work: the flag is a `:persistent_term`, which outlives the application
  # inside one VM (the tests stop and start it), so a stale `true` must not survive a restart.
  @impl true
  def init(:ok) do
    reset()
    {:ok, %{tokens: %{}, waiters: []}}
  end

  @impl true
  def handle_call({:enter, pid}, _from, state) do
    token = Process.monitor(pid)
    {:reply, token, put_in(state.tokens[token], pid)}
  end

  def handle_call(:count, _from, state), do: {:reply, map_size(state.tokens), state}

  def handle_call({:await, _timeout}, _from, %{tokens: tokens} = state) when map_size(tokens) == 0,
    do: {:reply, :ok, state}

  def handle_call({:await, timeout}, from, state) do
    timer = Process.send_after(self(), {:await_timeout, from}, timeout)
    {:noreply, %{state | waiters: [{from, timer} | state.waiters]}}
  end

  @impl true
  def handle_cast({:leave, token}, state), do: {:noreply, release(state, token)}

  @impl true
  def handle_info({:DOWN, token, :process, _pid, _reason}, state), do: {:noreply, release(state, token)}

  def handle_info({:await_timeout, from}, state) do
    case List.keytake(state.waiters, from, 0) do
      {{^from, _timer}, waiters} ->
        GenServer.reply(from, {:timeout, map_size(state.tokens)})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  defp release(state, token) do
    Process.demonitor(token, [:flush])
    state = %{state | tokens: Map.delete(state.tokens, token)}

    if map_size(state.tokens) == 0 do
      for {from, timer} <- state.waiters do
        Process.cancel_timer(timer)
        GenServer.reply(from, :ok)
      end

      %{state | waiters: []}
    else
      state
    end
  end
end
