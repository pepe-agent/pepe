defmodule Pepe.Repo.Migrations.AddRunToUsage do
  use Ecto.Migration

  def change do
    # Which run (one inbound message) a metered model call belongs to. Nullable: entries
    # recorded before this migration have no run, and background metering that happens
    # outside a run (session titling, compaction) legitimately has none either.
    alter table(:usage_entries) do
      add :run_id, :string
      add :session, :string
      add :source, :string
    end

    create index(:usage_entries, [:run_id])

    # Per-run metadata, and deliberately no money: what a run cost is always derived from
    # `usage_entries` (the ledger), so the two can never disagree about a number anybody
    # is billed for. This table only answers "what did that run *do*" - how long it took,
    # how it ended, which tools it called - durably, unlike `traces`, which carries the
    # transcript and is trimmed per scope.
    create table(:usage_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project, :string, null: false
      add :at, :integer, null: false
      add :agent, :string
      add :session, :string
      add :source, :string
      add :ms, :integer
      add :outcome, :string
      add :tools, {:array, :string}, default: []
    end

    create index(:usage_runs, [:project, :at])
    create index(:usage_runs, [:project, :session])
  end
end
