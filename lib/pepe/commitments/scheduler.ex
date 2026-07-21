defmodule Pepe.Commitments.Scheduler do
  @moduledoc """
  The in-app timer that fires due commitments. Ticks on a short interval, mirroring
  `Pepe.Watch.Scheduler`'s `deliver-when-reachable` contract: a failed delivery holds its
  text in `pending_delivery` and every tick retries it, without re-firing.

  The one real difference from Watch: what gets delivered depends on
  `commitment.origin_type`. A `"user_reminder"` is a canned message - `commitment.text`
  itself, same as any watch. An `"agent_promise"` is not: delivering "reminder: I said
  I'd check that" with nothing actually checked would be the exact honesty failure this
  feature exists to prevent, so it re-runs the *original* session instead - not a fresh
  ephemeral one the way `Pepe.Board.Scheduler` dispatches card work, since this is the
  user's real, ongoing conversation - and the agent's own genuine reply becomes the text
  that gets delivered.

  That difference is also why "at-most-once fire" needs its own state, `"firing"`,
  persisted before the text is produced rather than after (see `run_fire/1`): unlike
  Watch, where producing the text is free, `agent_promise` fulfillment is a real,
  possibly slow, possibly costly agent turn, and a crash partway through must never
  look like the fire never started to the next tick.
  """

  use GenServer
  use Gettext, backend: Pepe.Gettext
  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Watch.Delivery

  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Pepe.Config.Journal.put_source("commitments")
    schedule_tick()
    {:ok, %{busy: MapSet.new(), refs: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)
    state = Enum.reduce(Config.commitments(), state, &maybe_run(&1, &2, now))
    schedule_tick()
    {:noreply, state}
  end

  # A fire/delivery task ended, however it ended (a plain finish, a crash, an exit) -
  # clear the in-flight guard. Monitored (not a bare `Task.start` + self-reported
  # `{:done, id}`) so a task that dies partway through - an agent_promise's own session
  # crashing, the process being killed on shutdown - still releases its commitment
  # instead of leaving it stuck "in flight" forever, the same fix already applied to
  # Pepe.Cron.Scheduler. Note this only ever clears `busy`, never re-fires anything: a
  # commitment already past "scheduled" (into "firing") stays there - see run_fire/1.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} -> {:noreply, state}
      {id, refs} -> {:noreply, %{state | refs: refs, busy: MapSet.delete(state.busy, id)}}
    end
  end

  defp maybe_run(c, state, now) do
    cond do
      MapSet.member?(state.busy, c.id) ->
        state

      c.state == "scheduled" and is_integer(c.due_at) and now >= c.due_at ->
        start(c, state, &run_fire/1)

      # Fired earlier but delivery failed (channel unreachable, or the agent's own run
      # produced a reply we couldn't yet get out) - retry only the delivery.
      c.pending_delivery ->
        start(c, state, &run_retry/1)

      true ->
        state
    end
  end

  # Supervised (not a bare Task.start) so a graceful shutdown can see and drain in-flight
  # fires/deliveries instead of the VM just killing them - see Pepe.Application.prep_stop/1.
  # Monitored so the in-flight guard is released by the run ending, whatever ending it gets.
  defp start(c, state, fun) do
    case Task.Supervisor.start_child(Pepe.Commitments.TaskSupervisor, fn -> fun.(c) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | busy: MapSet.put(state.busy, c.id), refs: Map.put(state.refs, ref, c.id)}

      _ ->
        Logger.warning("commitment #{c.id}: could not start the run")
        state
    end
  end

  defp run_fire(c) do
    Pepe.Config.Journal.put_source("commitments")
    Config.put_locale()
    # Persist "firing" BEFORE producing the text - true at-most-once, unlike Watch's own
    # contract (which this used to just claim to match): a user_reminder's text is free
    # (it's just c.text), but an agent_promise's is not - fulfill/1 re-runs a whole real
    # session, which costs real money and can take real minutes, and a crash partway
    # through must never look like "never started" to the next tick. `maybe_run/3` only
    # ever fires from "scheduled", so a commitment stuck in "firing" (a crash before
    # `produce_text` returned) is left alone rather than silently re-run and possibly
    # billed and delivered twice - an operator can see it in the dashboard and re-schedule
    # or cancel it by hand. Accepting "possibly not delivered" over "possibly delivered
    # twice" is the same tradeoff `Pepe.DeliveryLedger` makes for a Telegram reply.
    firing = %{c | state: "firing", firing_at: System.system_time(:second)}
    Config.put_commitment(firing)

    text = produce_text(firing)
    updated = %{firing | state: "delivered", delivered_at: System.system_time(:second)}
    Config.put_commitment(updated)
    # `updated`, not `c`: deliver/2 may write pending_delivery back on failure, and
    # that write must build on the state just persisted, not the pre-fire snapshot.
    deliver(updated, text)
  end

  defp run_retry(c) do
    Pepe.Config.Journal.put_source("commitments")
    deliver(c, c.pending_delivery)
  end

  defp deliver(c, text) do
    case Delivery.deliver(c.origin, text) do
      :ok ->
        if c.pending_delivery, do: Config.put_commitment(%{c | pending_delivery: nil})

      {:error, reason} ->
        Logger.debug("[commitments] #{c.id} delivery deferred: #{inspect(reason)}")
        Config.put_commitment(%{c | pending_delivery: text})
    end
  end

  defp produce_text(%{origin_type: "agent_promise"} = c), do: fulfill(c)
  defp produce_text(c), do: c.text

  defp fulfill(%{origin: %{"key" => key}} = c) when is_binary(key) do
    case SessionSupervisor.ensure(key, c.agent) do
      {:ok, _pid} ->
        case Session.chat(key, prompt(c), []) do
          {:ok, reply} -> reply
          {:error, reason} -> gettext("(couldn't follow up on \"%{text}\": %{reason})", text: c.text, reason: inspect(reason))
        end

      _ ->
        gettext("(couldn't follow up on \"%{text}\": the conversation is gone)", text: c.text)
    end
  end

  defp fulfill(c), do: gettext("(couldn't follow up on \"%{text}\": no conversation to resume)", text: c.text)

  @prompt_note """
  Earlier in this conversation you said you would follow up on something. Do it now - \
  actually check or do the thing, don't just say you're checking - then reply with what \
  you found. This reply is delivered on its own, not shown next to your original message, \
  so make it stand on its own.
  """

  defp prompt(c), do: "#{@prompt_note}\nWhat you said you'd follow up on: #{c.text}"

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
