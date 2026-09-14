defmodule Pepe.Insight.Spec do
  @moduledoc """
  One row of `insight_specs` - what to predict, and from where. The schema is internal:
  `Pepe.Insight`'s public functions take/return bare string-keyed maps, same boundary
  convention as `Pepe.Graph.Definition`. `Pepe.Insight.Trainer`/`Source` work directly on
  this struct, since they're internal collaborators, not the public boundary.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "insight_specs" do
    field :agent, :string
    field :name, :string
    field :source_kind, :string, default: "db"
    field :connection, :string
    field :table, :string
    field :target_column, :string
    field :time_column, :string
    field :feature_columns, {:array, :string}, default: []
    field :task_type, :string, default: "classification"
    field :family, :string
    field :mode, :string, default: "manual"
    field :retrain_interval_s, :integer
    field :min_new_rows, :integer, default: 50
    field :row_count_at_last_train, :integer, default: 0
    field :status, :string, default: "pending"
    field :last_error, :string
    field :last_trained_at, :integer
    field :created_at, :integer
    field :updated_at, :integer
  end
end
