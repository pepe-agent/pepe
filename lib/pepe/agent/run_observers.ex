defmodule Pepe.Agent.RunObservers do
  @moduledoc """
  Dispatch and isolation for `Pepe.Agent.RunObserver` plugins - additive, unlike
  `Pepe.Slots` (there's no single "the" observer; any number can be installed at once).

  `attach/1` (called once, from `Pepe.Agent.Runtime.run/3`) resolves the installed,
  currently-enabled observers - once per run, not per event, both because
  `Pepe.Plugins.implementing/1` does real filesystem work and because a mid-run plugin
  edit taking effect only on the *next* run is the right semantics (no observer roster
  changing out from under an in-flight turn). If none are installed, this is a total
  no-op: no process spawned, no per-event overhead beyond a `Process.get/1`.

  Dispatch never runs in the run-owning process. `attach/1` spawns one unlinked "runner"
  process for the run (only when there's at least one observer), and `notify/1` is a bare
  `send/2` to it - never a wait, never a reply. The run process's own mailbox is never
  touched by anything in this module; a hung or crashing observer can only ever slow down
  its own run's runner, which nothing else depends on. The runner monitors the run
  process from the moment it's spawned and exits the instant either arrives: a clean
  `:run_end` (after draining whatever's still in flight) or the run process's own death
  (`:DOWN`) - covering every exit path `Pepe.Agent.Runtime.run/3` has, including a raise,
  since `finish/1` runs from a `try/after` there.

  An observer that fails 3 times in a row is disabled for the rest of the run AND every
  run after it, until manually reset - see `Pepe.Agent.RunObservers.Health`.

  `:tool_call` reaches an observer as `{:tool_call, name}`, WITHOUT its raw arguments:
  those are emitted before `Pepe.Tools.finalize/3`'s redaction has run and can carry
  secrets (a token on a `bash` command line, a credential in a `db_query`). `:tool_result`
  is unaffected - by the time it's emitted, it's already been through `finalize/3`.

  A queue that reaches 1,000 pending events for one run switches to dropping (logged
  once) for the rest of that run - a wedged runner costs bounded memory and zero turn
  latency, never an unbounded mailbox.
  """

  require Logger

  @pdict_key :pepe_run_observers
  @queue_cap 1_000
  @drain_timeout 5_000

  @doc """
  Start observing this run, if any observer is installed and enabled. Call once, from
  Runtime.run/3. Returns `:started` for the outermost run (the one that owns the
  attachment and must call `finish/1`) or `:nested` for a sub-agent run sharing the same
  process (e.g. via `send_to_agent`) - whose caller must NOT attach/finish over it, or
  the nested run's own finish would delete the outer run's runner mid-flight and silently
  drop every event the outer run emits afterward. Mirrors `Pepe.Trace.start/4`.
  """
  @spec attach(String.t()) :: :started | :nested
  def attach(agent_name) do
    case Process.get(@pdict_key) do
      nil ->
        case installed() do
          [] -> :ok
          observers -> start_runner(observers, wanted(observers), agent_name)
        end

        :started

      _ ->
        :nested
    end
  end

  defp wanted(observers), do: observers |> Enum.flat_map(& &1.subscriptions) |> Enum.uniq() |> MapSet.new()

  defp start_runner(observers, wanted, agent_name) do
    run_pid = self()

    result =
      Task.Supervisor.start_child(
        Pepe.Agent.RunObservers.TaskSupervisor,
        fn -> runner_init(observers, run_pid) end,
        restart: :temporary
      )

    case result do
      {:ok, runner} ->
        Process.put(@pdict_key, %{runner: runner, wanted: wanted, dropped: false})
        if MapSet.member?(wanted, :run_start), do: send(runner, {:pepe_run_observer, :run_start, {:run_start, agent_name}})

      _ ->
        Process.delete(@pdict_key)
    end
  end

  @doc "Forward a lifecycle event to this run's observers, if any want it. Never blocks, never raises."
  @spec notify(tuple()) :: :ok
  def notify(event) do
    case Process.get(@pdict_key) do
      nil -> :ok
      state -> Process.put(@pdict_key, dispatch(state, elem(event, 0), event))
    end

    :ok
  end

  @doc "End observation for this run - always call, even (especially) on an error/raise path. Safe to call more than once."
  @spec finish(atom()) :: :ok
  def finish(status) do
    case Process.get(@pdict_key) do
      nil -> :ok
      %{runner: runner} -> send(runner, {:pepe_run_observer, :run_end, {:run_end, status}})
    end

    Process.delete(@pdict_key)
    :ok
  end

  defp dispatch(%{dropped: true} = state, _type, _event), do: state

  defp dispatch(%{wanted: wanted, runner: runner} = state, type, event) do
    if MapSet.member?(wanted, type) do
      send_or_drop(state, runner, type, redacted(event))
    else
      state
    end
  end

  defp send_or_drop(state, runner, type, event) do
    case Process.info(runner, :message_queue_len) do
      {:message_queue_len, len} when len >= @queue_cap ->
        Logger.warning("[run_observers] event queue over #{@queue_cap} - dropping the rest of this run's events")
        %{state | dropped: true}

      _ ->
        send(runner, {:pepe_run_observer, type, event})
        state
    end
  end

  defp redacted({:tool_call, name, _raw}), do: {:tool_call, name}
  defp redacted(event), do: event

  defp installed do
    [{:name, 0}, {:subscriptions, 0}, {:handle_event, 3}]
    |> Pepe.Plugins.implementing()
    |> Enum.flat_map(&probe/1)
  end

  defp probe(mod) do
    with false <- Pepe.Agent.RunObservers.Health.disabled?(mod),
         {:ok, name} when is_binary(name) <- Pepe.Plugins.safe_call(mod, :name, []),
         {:ok, subs} when is_list(subs) <- Pepe.Plugins.safe_call(mod, :subscriptions, []) do
      [%{module: mod, name: name, subscriptions: subs}]
    else
      _ -> []
    end
  end

  ###
  ### the runner process - spawned unlinked, never the run-owning process
  ###

  defp runner_init(observers, run_pid) do
    ref = Process.monitor(run_pid)
    active = Map.new(observers, &{&1.module, %{subscriptions: &1.subscriptions, active: true}})
    runner_loop(active, ref)
  end

  defp runner_loop(active, ref) do
    receive do
      {:pepe_run_observer, :run_end, event} ->
        drain(dispatch_event(active, :run_end, event), ref)

      {:pepe_run_observer, type, event} ->
        runner_loop(dispatch_event(active, type, event), ref)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # send/2 ordering already guarantees nothing new arrives from the same sender after
  # :run_end, but a short grace window costs nothing and catches a straggler from a
  # concurrent tool Task, which sends independently of the run process itself.
  defp drain(active, ref) do
    receive do
      {:pepe_run_observer, type, event} ->
        drain(dispatch_event(active, type, event), ref)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    after
      @drain_timeout -> :ok
    end
  end

  defp dispatch_event(active, type, event) do
    Map.new(active, fn {mod, o} ->
      if o.active and type in o.subscriptions do
        {mod, %{o | active: safe_invoke(mod, type, event)}}
      else
        {mod, o}
      end
    end)
  end

  defp safe_invoke(mod, type, event) do
    mod.handle_event(type, event, %{ts: System.monotonic_time(:millisecond)})
    Pepe.Agent.RunObservers.Health.record_success(mod)
    true
  rescue
    e -> survive_failure(mod, type, Exception.message(e))
  catch
    kind, reason -> survive_failure(mod, type, "#{kind}: #{inspect(reason)}")
  end

  defp survive_failure(mod, type, detail) do
    Logger.warning("[run_observers] #{inspect(mod)} failed on #{type}: #{detail}")

    if Pepe.Agent.RunObservers.Health.record_failure(mod) do
      Logger.warning("[run_observers] #{inspect(mod)} failed 3 times in a row - disabling until manually reset")
      false
    else
      true
    end
  end
end
