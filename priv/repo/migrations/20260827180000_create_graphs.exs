defmodule Pepe.Repo.Migrations.CreateGraphs do
  use Ecto.Migration

  def change do
    create table(:graphs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :agent, :string, null: false
      add :entry, :string, null: false
      # Plain data (no DSL) - node shape, edges, and initial state defaults, all one
      # column written at save time and read together at run time. See Pepe.Graph's
      # moduledoc for the validated node/edge JSON shape.
      add :nodes, {:array, :map}, default: []
      add :state, :map, default: %{}
      add :max_steps, :integer, null: false, default: 25
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create index(:graphs, [:agent])
    create unique_index(:graphs, [:agent, :name])

    create table(:graph_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :graph_id, :string
      add :agent, :string, null: false
      add :graph_name, :string, null: false
      # Frozen at run start - editing or deleting the definition afterward never
      # corrupts an in-flight or finished run's own record of what it actually ran.
      add :definition, :map, default: %{}
      add :input, :string
      add :state, :map, default: %{}
      add :history, {:array, :map}, default: []
      add :current_node, :string
      add :visits, :map, default: %{}
      add :steps_taken, :integer, null: false, default: 0
      add :max_steps, :integer, null: false
      # Per-key taint, not one run-wide flag: only state keys a node's prompt actually
      # references get checked, so a node reading only clean keys stays untainted even
      # in a run where another branch touched outside content.
      add :tainted_keys, {:array, :string}, default: []
      # Set when the caller that started this run (run_graph, called from a live
      # conversation) was itself already tainted - every node starts untrusted
      # regardless of which keys it reads, the same over-taint `delegate`'s own
      # `untrusted: Permissions.tainted?(ctx)` forwarding already accepts.
      add :tainted_from_start, :boolean, null: false, default: false
      # running | waiting_human | done | failed
      add :status, :string, null: false, default: "running"
      add :error, :string
      add :session_key, :string
      add :origin, :map, default: %{}
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :finished_at, :integer
    end

    create index(:graph_runs, [:status])
    create index(:graph_runs, [:agent, :graph_name])
    create index(:graph_runs, [:created_at])
  end
end
