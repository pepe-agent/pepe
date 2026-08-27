defmodule Pepe.Graph.Definition do
  @moduledoc """
  One row of `Pepe.Graph` - see that module's moduledoc for the node/edge JSON shape
  `nodes` and `state` hold. The schema is internal: every public `Pepe.Graph` function
  takes/returns a bare string-keyed map, not this struct - same boundary convention as
  `Pepe.Flow.Flow`.
  """

  use Ecto.Schema

  # App-generated string id, not Ecto's autoincrement - matches every other operational
  # subsystem's id shape (Pepe.Flow.Flow, Pepe.Permissions.PendingApproval, ...).
  @primary_key {:id, :string, autogenerate: false}
  schema "graphs" do
    field :name, :string
    field :agent, :string
    field :entry, :string
    field :nodes, {:array, :map}, default: []
    field :state, :map, default: %{}
    field :max_steps, :integer, default: 25
    field :created_at, :integer
    field :updated_at, :integer
  end
end
