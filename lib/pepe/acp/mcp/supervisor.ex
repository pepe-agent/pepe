defmodule Pepe.ACP.Mcp.Supervisor do
  @moduledoc """
  What keeps editor-supplied MCP servers running: the `Pepe.ACP.Mcp.Manager` that knows
  which server belongs to which ACP session, and the supervisors their clients run under.

  The clients run under a `PartitionSupervisor` of dynamic supervisors rather than the one
  `Pepe.MCP` uses for configured servers. Starting a client blocks the supervisor doing it
  for as long as the handshake takes (up to thirty seconds for a server that never
  answers), and a server an editor hands over is more likely to be broken than one an
  operator installed on purpose. Kept apart, a hung one delays other editor-supplied
  servers that hash to the same partition and never a configured server; spread over
  partitions, it rarely delays even those.
  """

  use Supervisor

  @dynsup Pepe.ACP.Mcp.DynSup

  @doc "The name of the partitioned dynamic supervisor editor-supplied clients start under."
  def dynsup, do: @dynsup

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {PartitionSupervisor, child_spec: DynamicSupervisor, name: @dynsup},
      Pepe.ACP.Mcp.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
