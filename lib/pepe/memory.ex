defmodule Pepe.Memory do
  @moduledoc """
  The facade every caller searches memory through - routes to whichever backend currently
  occupies the `memory` slot (see `Pepe.Slots`), degrading to the builtin lexical search on
  a misbehaving occupant (see `Pepe.Slots.Guard`). `Pepe.Tools.MemorySearch` is a thin
  wrapper over this; nothing else needs to know a slot exists.
  """

  alias Pepe.Memory.Hit

  @doc """
  Search `agent_name`'s memory for `query`. `opts`: `:limit`, `:mode` (`:keyword | :vector |
  :hybrid`, a hint only). `agent` (the full struct, not just its name) is optional - pass it
  when known so a per-agent slot override (`Pepe.Slots.occupant/2`) is actually honored,
  instead of falling back to the installation-wide occupant.
  """
  @spec search(String.t(), String.t(), keyword(), Pepe.Config.Agent.t() | nil) ::
          {:ok, [Hit.t()]} | {:error, term()}
  def search(agent_name, query, opts \\ [], agent \\ nil) do
    Pepe.Slots.Guard.call("memory", :search, [agent_name, query, opts], agent)
  end

  @doc "Ask the current occupant to rebuild its index for `agent_name`, if it maintains one. A no-op for a backend (like the builtin) that has nothing to index."
  @spec reindex(String.t()) :: :ok | {:error, term()}
  def reindex(agent_name) do
    mod = Pepe.Slots.occupant("memory")

    if function_exported?(mod, :index, 1) do
      Pepe.Slots.Guard.call("memory", :index, [agent_name])
    else
      :ok
    end
  end

  @doc "The current occupant's name and capabilities - for `mix pepe slot list`/Doctor/the dashboard."
  @spec status() :: %{occupant: String.t(), capabilities: %{keyword: boolean(), vector: boolean()}}
  def status do
    mod = Pepe.Slots.occupant("memory")

    name =
      case Pepe.Plugins.safe_call(mod, :name, []) do
        {:ok, n} when is_binary(n) -> n
        _ -> inspect(mod)
      end

    caps =
      if function_exported?(mod, :capabilities, 0) do
        case Pepe.Plugins.safe_call(mod, :capabilities, []) do
          {:ok, caps} -> caps
          _ -> %{keyword: true, vector: false}
        end
      else
        %{keyword: true, vector: false}
      end

    %{occupant: name, capabilities: caps}
  end
end
