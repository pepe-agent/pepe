defmodule Pepe.Scheduler.Guard do
  @moduledoc """
  The busy-tracking + monitored-task machinery every in-app scheduler (`Pepe.Watch.Scheduler`,
  `Pepe.Commitments.Scheduler`, `Pepe.Board.Scheduler`, `Pepe.Cron.Scheduler`,
  `Pepe.Insight.Scheduler`) used to hand-roll identically: which ids currently have a run in
  flight, launching a new run under a `Task.Supervisor`, and releasing the guard on that
  task's `:DOWN` - however the task ended (finished, crashed, killed at shutdown). A message
  is the only reliable release: a cleanup step that runs "at the end" never runs for a task
  that never reaches its end, and an id whose guard is never released silently stops firing
  forever.

  Each scheduler stays its own `GenServer` (own supervision entry, own `Task.Supervisor`,
  own `due?`/dispatch logic - that part is genuinely different per domain and isn't what
  this factors out). This is a plain value carried in each scheduler's own state, not a
  process of its own:

      def init(_opts) do
        schedule_tick()
        {:ok, %{guard: Guard.new(), ...}}
      end

      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        case Guard.down(state.guard, ref) do
          :not_found -> {:noreply, state}
          {_id, _payload, guard} -> {:noreply, %{state | guard: guard}}
        end
      end

  `start/6`'s `down_payload` is what `down/2` hands back on that id's `:DOWN` - `start/5`
  defaults it to `id` again, but a scheduler that needs more (`Pepe.Board.Scheduler` needs
  `claimed_by`/`claimed_at` alongside the card id to call `block_if_still_running/3`) can
  carry it separately from the busy-tracking key via `start/6`.
  """

  require Logger

  @type id :: term()
  @type t :: %__MODULE__{running: %{id() => reference()}, refs: %{reference() => {id(), term()}}}
  defstruct running: %{}, refs: %{}

  @doc "A fresh, empty guard."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Does `id` currently have a run in flight?"
  @spec busy?(t(), id()) :: boolean()
  def busy?(%__MODULE__{} = guard, id), do: Map.has_key?(guard.running, id)

  @doc "Every id with a run in flight right now."
  @spec running_ids(t()) :: [id()]
  def running_ids(%__MODULE__{} = guard), do: Map.keys(guard.running)

  @doc """
  Start `fun` under `supervisor`, monitored, and record it as running under `id` (whose
  `:DOWN` payload defaults to `id` itself - see `start/6` for a custom one). Logs and
  returns the guard unchanged if the supervisor declines to start the task (e.g. an
  `:error` return from `DynamicSupervisor`'s own child-spec limits) - same as every
  scheduler already handled before this was factored out. A `supervisor` that isn't a live
  process at all still raises, exactly as a direct `Task.Supervisor.start_child/2` call
  would: that is a broken supervision tree, not a per-run failure to degrade around.

  `label` names the caller's domain in the "could not start" log line (e.g. `"cron"`,
  `"watch"`) - purely cosmetic, but it's what makes that line greppable/alertable per
  scheduler again, the way each one's own hand-rolled version used to be before this
  module existed. Required, not defaulted: `start/5` and `start/6` are two explicit
  function clauses rather than one definition with two optional arguments in different
  positions, so a call can never land on the wrong arity by accident.
  """
  @spec start(t(), Supervisor.supervisor(), id(), (-> any()), String.t()) :: t()
  def start(%__MODULE__{} = guard, supervisor, id, fun, label) when is_function(fun, 0) do
    start(guard, supervisor, id, id, fun, label)
  end

  @doc "Like `start/5`, but `down_payload` (not `id`) is what `down/2` hands back on this run's `:DOWN`."
  @spec start(t(), Supervisor.supervisor(), id(), term(), (-> any()), String.t()) :: t()
  def start(%__MODULE__{} = guard, supervisor, id, down_payload, fun, label) when is_function(fun, 0) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{guard | running: Map.put(guard.running, id, ref), refs: Map.put(guard.refs, ref, {id, down_payload})}

      _ ->
        Logger.warning("#{label} #{inspect(id)}: could not start a run")
        guard
    end
  end

  @doc """
  Handle a task's `:DOWN` message. Returns `{id, down_payload, guard}` with that id's guard
  released if `ref` belonged to this guard, `:not_found` for a `:DOWN` from anything else
  (including a second `:DOWN` for an id already released, or one it never held).
  """
  @spec down(t(), reference()) :: {id(), term(), t()} | :not_found
  def down(%__MODULE__{} = guard, ref) do
    case Map.pop(guard.refs, ref) do
      {nil, _} ->
        :not_found

      {{id, payload}, refs} ->
        # Only clear `running[id]` if `ref` is still the CURRENT run for that id - a
        # scheduler that allows overlapping runs for the same id (Pepe.Cron.Scheduler's
        # `overlap: true`) can have a second `start/6` overwrite `running[id]` with a newer
        # ref while the first run is still in flight; that first run's own `:DOWN` must not
        # then erase the second (still-live) run's busy marker.
        running = if Map.get(guard.running, id) == ref, do: Map.delete(guard.running, id), else: guard.running
        {id, payload, %{guard | refs: refs, running: running}}
    end
  end
end
