defmodule Cortex.Agent.SessionSupervisor do
  @moduledoc "Dynamic supervisor for live conversation sessions."
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start (or return the existing) session process for the given key."
  def ensure(key, agent_name) do
    case Registry.lookup(Cortex.Agent.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Cortex.Agent.Session, key: key, agent_name: agent_name}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
