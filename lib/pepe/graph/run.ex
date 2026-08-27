defmodule Pepe.Graph.Run do
  @moduledoc """
  One execution of a `Pepe.Graph.Definition` - see `Pepe.Graph.Runner`'s moduledoc for
  the loop that reads/writes this row. `definition` is a frozen snapshot taken at run
  start, so editing or deleting the definition afterward never corrupts an in-flight or
  finished run's own record of what it actually ran.

  `tainted_keys` is per-`state`-key, not one run-wide flag: a node's prompt only pulls
  in the taint of the specific state keys it actually references (see
  `Pepe.Graph.Prompt.referenced_keys/1`), so a node reading only clean keys stays
  untainted even inside a run where another branch touched outside content.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "graph_runs" do
    field :graph_id, :string
    field :agent, :string
    field :graph_name, :string
    field :definition, :map, default: %{}
    field :input, :string
    field :state, :map, default: %{}
    field :history, {:array, :map}, default: []
    field :current_node, :string
    field :visits, :map, default: %{}
    field :steps_taken, :integer, default: 0
    field :max_steps, :integer
    field :tainted_keys, {:array, :string}, default: []
    field :tainted_from_start, :boolean, default: false
    # running | waiting_human | done | failed
    field :status, :string, default: "running"
    field :error, :string
    field :session_key, :string
    field :origin, :map, default: %{}
    field :created_at, :integer
    field :updated_at, :integer
    field :finished_at, :integer
  end

  @fields ~w(id graph_id agent graph_name definition input state history current_node
             visits steps_taken max_steps tainted_keys tainted_from_start status error
             session_key origin created_at updated_at finished_at)a

  @doc "Build a changeset over the castable fields, used only for the initial insert."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:id, :agent, :graph_name, :max_steps])
    |> validate_inclusion(:status, ~w(running waiting_human done failed))
  end

  @type t :: %__MODULE__{}
end
