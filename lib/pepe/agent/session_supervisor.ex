defmodule Pepe.Agent.SessionSupervisor do
  @moduledoc "Dynamic supervisor for live conversation sessions."
  use DynamicSupervisor

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
  its own history in `init/1`.
  """
  def restore do
    if persist?() do
      for {key, agent_name} <- Pepe.Agent.SessionPersistence.all() do
        ensure(key, agent_name)
      end
    end

    :ok
  end

  defp persist?, do: Application.get_env(:pepe, :persist_sessions, false)

  @doc "Start (or return the existing) session process for the given key."
  def ensure(key, agent_name) do
    case Registry.lookup(Pepe.Agent.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Pepe.Agent.Session, key: key, agent_name: agent_name}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
