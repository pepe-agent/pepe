defmodule Pepe.Commitments.Scheduler do
  @moduledoc """
  The in-app timer that fires due commitments. Ticks on a short interval, mirroring
  `Pepe.Watch.Scheduler` exactly (`at-most-once` fire: persisted before delivery is
  attempted; `deliver-when-reachable`: a failed delivery holds its text in
  `pending_delivery` and every tick retries it, without re-firing).

  The one real difference from Watch: what gets delivered depends on
  `commitment.origin_type`. A `"user_reminder"` is a canned message - `commitment.text`
  itself, same as any watch. An `"agent_promise"` is not: delivering "reminder: I said
  I'd check that" with nothing actually checked would be the exact honesty failure this
  feature exists to prevent, so it re-runs the *original* session instead - not a fresh
  ephemeral one the way `Pepe.Board.Scheduler` dispatches card work, since this is the
  user's real, ongoing conversation - and the agent's own genuine reply becomes the text
  that gets delivered.
  """

  use GenServer
  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Watch.Delivery

  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{busy: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)
    busy = Enum.reduce(Config.commitments(), state.busy, &maybe_run(&1, &2, now))
    schedule_tick()
    {:noreply, %{state | busy: busy}}
  end

  # A fire/delivery task finished for this commitment id - clear the in-flight guard.
  def handle_info({:done, id}, state),
    do: {:noreply, %{state | busy: MapSet.delete(state.busy, id)}}

  defp maybe_run(c, busy, now) do
    cond do
      MapSet.member?(busy, c.id) ->
        busy

      c.state == "scheduled" and is_integer(c.due_at) and now >= c.due_at ->
        run_fire(c)
        MapSet.put(busy, c.id)

      # Fired earlier but delivery failed (channel unreachable, or the agent's own run
      # produced a reply we couldn't yet get out) - retry only the delivery.
      c.pending_delivery ->
        run_retry(c)
        MapSet.put(busy, c.id)

      true ->
        busy
    end
  end

  defp run_fire(c) do
    parent = self()

    Task.start(fn ->
      text = produce_text(c)
      # Persist "delivered" BEFORE attempting delivery - at-most-once fire, same
      # contract as Watch. If producing the text itself crashed (the agent_promise
      # path re-runs a real session), this line is never reached and the next tick
      # simply retries the whole thing - no bounded-retry bookkeeping, same tolerance
      # the rest of this codebase already has for a crashing check/dispatch.
      updated = %{c | state: "delivered", delivered_at: System.system_time(:second)}
      Config.put_commitment(updated)
      # `updated`, not `c`: deliver/2 may write pending_delivery back on failure, and
      # that write must build on the state just persisted, not the pre-fire snapshot.
      deliver(updated, text)
      send(parent, {:done, c.id})
    end)
  end

  defp run_retry(c) do
    parent = self()

    Task.start(fn ->
      deliver(c, c.pending_delivery)
      send(parent, {:done, c.id})
    end)
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
          {:error, reason} -> "(couldn't follow up on \"#{c.text}\": #{inspect(reason)})"
        end

      _ ->
        "(couldn't follow up on \"#{c.text}\": the conversation is gone)"
    end
  end

  defp fulfill(c), do: "(couldn't follow up on \"#{c.text}\": no conversation to resume)"

  @prompt_note """
  Earlier in this conversation you said you would follow up on something. Do it now - \
  actually check or do the thing, don't just say you're checking - then reply with what \
  you found. This reply is delivered on its own, not shown next to your original message, \
  so make it stand on its own.
  """

  defp prompt(c), do: "#{@prompt_note}\nWhat you said you'd follow up on: #{c.text}"

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
