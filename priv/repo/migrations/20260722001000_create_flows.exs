defmodule Pepe.Repo.Migrations.CreateFlows do
  use Ecto.Migration

  def change do
    create table(:flows, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :agent, :string, null: false
      # Ordered, literal (no templating - see Pepe.Flow's moduledoc for why v1 stays
      # exact-replay-only). One column: written once at promotion time, read together at
      # run time, never queried on an individual step.
      add :steps, {:array, :map}, default: []
      add :source_trace_ids, {:array, :string}, default: []
      add :created_at, :integer, null: false
      add :last_run, :integer
      add :last_result, :string
    end

    create index(:flows, [:agent])
    create unique_index(:flows, [:agent, :name])
  end
end
