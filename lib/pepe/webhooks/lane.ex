defmodule Pepe.Webhooks.Lane do
  @moduledoc """
  One conversation's inbound messages, taken in the order they were received.

  Every webhook message used to run in a process of its own, so the order in which two
  messages from the same person reached the agent was the order in which their processes
  finished the work in front of them. Text is instant; a voice note is a download and a
  transcription. Send the note and then a question and the question was answered first, about
  a conversation the note had not yet joined.

  A lane fixes that without giving up what the platform already does well:

    * **Order is per conversation.** The lane is keyed by the session key, so two people
      (or two channels) never wait for each other, and the lane goes away by itself after
      30 seconds of nothing to do, so an idle conversation costs no process.
    * **The wait is only for what must be in order.** A message is resolved (downloaded,
      transcribed) one at a time, then handed to the session with `Pepe.Agent.Session.send_chat/5`,
      which returns as soon as it is in the session's queue. The lane does *not* wait for the
      agent's reply before taking the next message: a person who sends a correction while the
      agent is working still reaches the turn that is running (`midrun_fold`) or waits behind it
      in the session's own queue, exactly as before.
    * **The queue is bounded.** At most 50 messages wait per conversation; the rest are
      refused (and logged) instead of growing without limit while a slow download blocks the
      front of the line.

  What runs in a task and what runs in the lane is deliberate: resolving media and delivering
  replies are slow and are done in supervised tasks; the small state changes that the next
  message depends on (starting a session, `/new`, `/mention`) are done in the lane, so they are
  finished before the next message is looked at.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Pepe.Agent.Session

  @max_queue 50
  @idle_ms 30_000

  defstruct key: nil, queue: :queue.new(), resolving: nil, requests: nil

  # A defensive backstop, not the real bound: resolving is already bounded by
  # Pepe.Webhooks.Media.Download's own ~120s and Pepe.Media's own ~60s per step. This only
  # protects against a future unbounded step somewhere in that chain freezing this
  # conversation's lane forever - the queue would fill, and it would never idle-exit.
  # `:webhook_lane_deadline_ms` exists for a test that wants to see it fire without waiting
  # three real minutes; nothing else sets it.
  defp job_deadline_ms, do: Application.get_env(:pepe, :webhook_lane_deadline_ms, 180_000)

  @doc """
  Put `job` (`%{entry:, mod:, message:, callers:}`) at the back of conversation `key`'s
  lane, starting the lane if it is not running. `:ok`, or `{:error, :full}` when the lane
  already holds 50 waiting messages.
  """
  @spec submit(String.t(), map()) :: :ok | {:error, :full | :unavailable}
  def submit(key, job), do: submit(key, job, 3)

  # A lane that is shutting down when the call reaches it is not an error: the next attempt
  # starts a fresh one.
  defp submit(_key, _job, 0), do: {:error, :unavailable}

  defp submit(key, job, attempts) do
    case DynamicSupervisor.start_child(Pepe.Webhooks.LaneSup, {__MODULE__, key}) do
      {:ok, pid} -> call(pid, key, job, attempts)
      {:error, {:already_started, pid}} -> call(pid, key, job, attempts)
      _ -> {:error, :unavailable}
    end
  end

  defp call(pid, key, job, attempts) do
    GenServer.call(pid, {:job, job})
  catch
    :exit, _ -> submit(key, job, attempts - 1)
  end

  def start_link(key), do: GenServer.start_link(__MODULE__, key, name: {:via, Registry, {Pepe.Webhooks.LaneRegistry, key}})

  @impl true
  def init(key), do: {:ok, %__MODULE__{key: key, requests: :gen_server.reqids_new()}}

  @impl true
  def handle_call({:job, job}, _from, state) do
    if :queue.len(state.queue) >= @max_queue do
      {:reply, {:error, :full}, state, timeout(state)}
    else
      state = pump(%{state | queue: :queue.in(job, state.queue)})
      {:reply, :ok, state, timeout(state)}
    end
  end

  @impl true
  # The message being resolved finished: carry on with what it became.
  def handle_info({ref, result}, %{resolving: %{task: %{ref: ref}, job: job, deadline: deadline}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(deadline)
    state = pump(begin(%{state | resolving: nil}, job, result))
    {:noreply, state, timeout(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{resolving: %{task: %{ref: ref}, job: job, deadline: deadline}} = state
      ) do
    Process.cancel_timer(deadline)
    Logger.warning("[webhooks] #{job.entry["slug"]}: resolving a message from #{job.message.from} crashed: #{inspect(reason)}")
    state = pump(%{state | resolving: nil})
    {:noreply, state, timeout(state)}
  end

  # The job in front of the line has been resolving longer than any real step in that chain
  # should ever take - see @job_deadline_ms. `Task.shutdown/2` also accounts for the task's
  # own reply or DOWN message, wherever it eventually lands, so nothing further is needed for
  # either once this runs.
  def handle_info({:deadline, ref}, %{resolving: %{task: %{ref: ref} = task, job: job}} = state) do
    Logger.warning("[webhooks] #{job.entry["slug"]}: resolving a message from #{job.message.from} took too long and was stopped")
    Task.shutdown(task, :brutal_kill)
    state = pump(%{state | resolving: nil})
    {:noreply, state, timeout(state)}
  end

  def handle_info({:deadline, _ref}, state), do: {:noreply, state}

  def handle_info(:timeout, state) do
    if idle?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  # Anything else is either the session answering a message handed to it, or noise.
  def handle_info(message, state) do
    state =
      case :gen_server.check_response(message, state.requests, true) do
        {response, job, requests} ->
          finish(job, response)
          %{state | requests: requests}

        _ ->
          state
      end

    {:noreply, state, timeout(state)}
  end

  ###
  ### the front of the line
  ###

  defp pump(%{resolving: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, job}, rest} ->
        task =
          Task.Supervisor.async_nolink(Pepe.Webhooks.TaskSupervisor, fn ->
            inherit_callers(job)
            Pepe.Config.put_locale()
            Pepe.Webhooks.prepare(job)
          end)

        deadline = Process.send_after(self(), {:deadline, task.ref}, job_deadline_ms())
        %{state | queue: rest, resolving: %{task: task, job: job, deadline: deadline}}

      {:empty, _} ->
        state
    end
  end

  defp pump(state), do: state

  # Resolved: `:ignore` (nothing to answer) moves on; anything else is decided now, in the
  # lane, so its effects are in place before the next message is looked at.
  defp begin(state, _job, :ignore), do: state

  defp begin(state, job, {:ok, text, opts}) do
    inherit_callers(job)

    case Pepe.Webhooks.begin(job, text, opts) do
      {:chat, key, text, chat_opts} ->
        %{state | requests: Session.send_chat(key, text, chat_opts, job, state.requests)}

      :done ->
        state
    end
  rescue
    e ->
      Logger.warning("[webhooks] #{job.entry["slug"]}: could not start a turn for #{job.message.from}: #{Exception.message(e)}")
      state
  catch
    :exit, reason ->
      Logger.warning("[webhooks] #{job.entry["slug"]}: could not start a turn for #{job.message.from}: #{inspect(reason)}")
      state
  end

  # The session's answer, delivered off the lane so a slow platform never holds the next
  # message up.
  defp finish(job, response) do
    result =
      case response do
        {:reply, reply} -> reply
        {:error, {reason, _server}} -> {:error, reason}
      end

    Task.Supervisor.start_child(Pepe.Webhooks.TaskSupervisor, fn ->
      inherit_callers(job)
      Pepe.Config.put_locale()
      Pepe.Webhooks.finish(job, result)
    end)
  end

  # `$callers` is how a test's stubs (and a trace) follow work across processes; the lane
  # is started by a supervisor, so the link to whoever submitted the message is carried in
  # the job and put back in each task that works on it.
  defp inherit_callers(%{callers: callers}) when is_list(callers), do: Process.put(:"$callers", callers)
  defp inherit_callers(_job), do: :ok

  defp idle?(state),
    do: state.resolving == nil and :queue.is_empty(state.queue) and :gen_server.reqids_size(state.requests) == 0

  defp timeout(state), do: if(idle?(state), do: @idle_ms, else: :infinity)
end
