defmodule Pepe.Repo.Migrations.CreateInsight do
  use Ecto.Migration

  def change do
    create table(:insight_specs, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent, :string, null: false
      add :name, :string, null: false
      # "db" - rows come from a registered Pepe.DB connection - or "import" - rows were
      # handed in directly (insight_examples), the path any other data source (anything
      # reachable via bash + a database CLI, or a future GoalLoop producer) goes through.
      add :source_kind, :string, null: false, default: "db"
      # Only set (and only meaningful) when source_kind == "db" - validated at call sites,
      # not a DB constraint, same convention as the rest of this codebase's operational tables.
      add :connection, :string
      add :table, :string
      # Required for "classification"/"regression"/"forecast" (validated at call sites);
      # nil for "clustering", which has no target to predict.
      add :target_column, :string
      # Required for "forecast" only - the timestamp column it predicts the target over.
      add :time_column, :string
      add :feature_columns, {:array, :string}, null: false, default: []
      # "classification" | "regression" | "clustering" | "forecast"
      add :task_type, :string, null: false, default: "classification"
      # nil (default) = auto-picked by data volume, same "Pepe decides" default as
      # everywhere else. "linear" | "gbm" | "neural" - an explicit override for an operator
      # who wants to force a specific family instead of the automatic volume-based choice.
      # Ignored (forced nil) for "clustering", which always uses k-means regardless.
      add :family, :string
      # "manual" | "auto" - provenance only (which flow created it), never a live behavior branch.
      add :mode, :string, null: false, default: "manual"
      # nil = no scheduled retrain, only explicit train_now.
      add :retrain_interval_s, :integer
      add :min_new_rows, :integer, null: false, default: 50
      add :row_count_at_last_train, :integer, null: false, default: 0
      # pending | training | ready | failed
      add :status, :string, null: false, default: "pending"
      add :last_error, :string
      add :last_trained_at, :integer
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create index(:insight_specs, [:agent])
    create unique_index(:insight_specs, [:agent, :name])

    create table(:insight_models, primary_key: false) do
      add :id, :string, primary_key: true
      add :spec_id, :string, null: false
      add :version, :integer, null: false
      # "logistic_regression" | "linear_regression" | "gbm_classifier" | "gbm_regressor" |
      # "neural_classifier" | "neural_regressor" | "kmeans" - picked automatically by data
      # volume/task_type (see Pepe.Insight.Trainer), never a user choice.
      add :algorithm, :string, null: false
      add :task_type, :string, null: false
      add :feature_columns, {:array, :string}, null: false, default: []
      add :sample_count, :integer, null: false
      add :metric_name, :string, null: false
      add :metric_value, :float, null: false
      # Fit-time bookkeeping the predictor needs back (e.g. classification's label
      # encoding under "classes", the feature-standardization "scale") - never the
      # artifact itself, that's `artifact` below.
      add :params, :map, default: %{}
      # Nx.serialize/1 of the fitted Scholar/Axon struct, except for "gbm_classifier"/
      # "gbm_regressor" (EXGBoost.dump_model/1's own native format) - see
      # Pepe.Insight.Model's moduledoc.
      add :artifact, :binary, null: false
      add :trained_at, :integer, null: false
      add :created_at, :integer, null: false
    end

    create index(:insight_models, [:spec_id])
    create unique_index(:insight_models, [:spec_id, :version])

    create table(:insight_examples, primary_key: false) do
      add :id, :string, primary_key: true
      add :spec_id, :string, null: false
      add :agent, :string, null: false
      add :features, :map, default: %{}
      add :target, :string
      add :batch_id, :string
      add :inserted_at, :integer, null: false
    end

    create index(:insight_examples, [:spec_id, :inserted_at])
  end
end
