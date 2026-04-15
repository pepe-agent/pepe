defmodule Pepe.Agent.SessionSupervisor do
  @moduledoc "Dynamic supervisor for live conversation sessions."
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "All live session keys, registered in `Pepe.Agent.Registry`."
  def list do
    Registry.select(Pepe.Agent.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Terminate a session (and forget its permission grants + persisted file)."
  def terminate(key) do
    Pepe.Permissions.SessionStore.clear(key)
    if persist?(), do: Pepe.Agent.SessionPersistence.delete(key)

    case Registry.lookup(Pepe.Agent.Registry, key) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc """
  Re-spawn the persisted sessions on boot, so conversations survive a restart.
  No-op unless session persistence is on (serve/gateway). Each session restores
  its own history in `init/1`. A session left with a **pending** marker (its last
  turn was still running when the process went down - see
  `Pepe.Agent.SessionPersistence`) gets its interrupted turn resumed and the reply
  pushed back to wherever it came from, so a crash/restart mid-answer doesn't just
  leave the user hanging.
  """
  def restore do
    if persist?() do
      for {key, agent_name, pending} <- Pepe.Agent.SessionPersistence.all() do
        {:ok, _pid} = ensure(key, agent_name)
        if pending, do: resume_and_deliver(key)
      end
    end

    :ok
  end

  # Best-effort: replay the interruption as an internal turn (see
  # `Pepe.Agent.Session.resume/1`) and push whatever the agent replies to the
  # channel the session came from, reusing the same origin/delivery Pepe.Watch
  # uses for fired watches. Unlike a watch, there's no durable retry queue here -
  # a delivery that fails (e.g. the channel isn't reachable yet at boot) is logged
  # and dropped, though the reply itself is still saved into the session's history
  # either way, so it's there next time the conversation is opened.
  defp resume_and_deliver(key) do
    Task.start(fn ->
      case Pepe.Agent.Session.resume(key) do
        {:ok, text} ->
          origin = Pepe.Watch.Delivery.origin_from_ctx(%{session_key: key})

          case Pepe.Watch.Delivery.deliver(origin, text) do
            :ok -> :ok
            {:error, reason} -> Logger.warning("[session] #{key} resume reply undelivered: #{inspect(reason)}")
          end

        :nothing_pending ->
          :ok

        {:error, reason} ->
          Logger.warning("[session] #{key} resume failed: #{inspect(reason)}")
      end
    end)
  end

  # See the matching guard (and its rationale) in Pepe.Agent.Session.
  defp persist?,
    do: Application.get_env(:pepe, :env) != :test and Application.get_env(:pepe, :persist_sessions, false)

  @doc """
  Start (or return the existing) session process for the given key. `opts` are
  passed to the session on first creation (e.g. `ttl_ms:`, `ephemeral:`); an
  already-running session keeps the options it was created with.
  """
  def ensure(key, agent_name, opts \\ []) do
    case Registry.lookup(Pepe.Agent.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Pepe.Agent.Session, [key: key, agent_name: agent_name] ++ opts}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
