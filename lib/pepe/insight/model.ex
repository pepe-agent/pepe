defmodule Pepe.Insight.Model do
  @moduledoc """
  One trained artifact version for a `Pepe.Insight.Spec`. `artifact` is `Nx.serialize/1` of
  the fitted Scholar/Axon struct, not `:erlang.term_to_binary/1` - Nx's documented path for
  tensors/tensor-containing structs, so it stays readable across backend/version changes,
  unlike the raw term shape (which is backend-specific even though the default
  `Nx.BinaryBackend` happens to look like a plain binary today). The exception is
  `"gbm_classifier"`/`"gbm_regressor"`, whose `artifact` is `EXGBoost.dump_model/1`'s own
  native binary format instead (see `Pepe.Insight.Predictor.deserialize/2`, the read side
  of this split). Small (KB, not MB) for every algorithm here, fine as a SQLite blob.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "insight_models" do
    field :spec_id, :string
    field :version, :integer
    field :algorithm, :string
    field :task_type, :string
    field :feature_columns, {:array, :string}, default: []
    field :sample_count, :integer
    field :metric_name, :string
    field :metric_value, :float
    field :params, :map, default: %{}
    field :artifact, :binary
    field :trained_at, :integer
    field :created_at, :integer
  end
end
