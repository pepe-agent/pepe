defmodule Pepe.Repo.Migrations.CreateCommitments do
  use Ecto.Migration

  def change do
    create table(:commitments, primary_key: false) do
      add :id, :string, primary_key: true
      add :text, :text
      add :source_excerpt, :text
      add :due_when, :string
      add :due_at, :integer
      add :origin_type, :string, null: false, default: "user_reminder"
      add :agent, :string
      add :origin, :map, default: %{}
      add :confidence, :float
      add :state, :string, null: false, default: "awaiting_confirmation"
      add :created_at, :integer
      add :delivered_at, :integer
      add :last_error, :text
      add :pending_delivery, :text
      add :firing_at, :integer
      add :normalized_text, :string
    end

    # Supports the scheduler's tick query (state == "scheduled" and due_at <= now) as an
    # index range scan instead of a full table scan as commitments accumulate - the actual
    # point of this migration.
    create index(:commitments, [:state, :due_at])
    create index(:commitments, [:agent])

    # The DB-level replacement for the old in-process CAS duplicate check
    # (Pepe.Config.create_commitment/1): a stronger guarantee than before, since it holds
    # across concurrent OS processes, not just within one BEAM's Config.Writer. SQLite
    # re-evaluates a partial index's predicate on every UPDATE, so a commitment that
    # transitions out of the active states automatically stops being enforced against.
    #
    # No custom :name here, deliberately: SQLite's own UNIQUE-violation error text names
    # only the columns, never the index, so ecto_sqlite3 maps a violation back to a
    # changeset's unique_constraint/3 by re-deriving Ecto's own conventional name
    # ("commitments_agent_normalized_text_index") from those columns - a custom name on
    # either side would silently stop matching and the raw Ecto.ConstraintError would
    # bubble up unhandled instead of becoming `{:error, changeset}`.
    create unique_index(:commitments, [:agent, :normalized_text],
             where: "state IN ('awaiting_confirmation', 'scheduled')"
           )
  end
end
