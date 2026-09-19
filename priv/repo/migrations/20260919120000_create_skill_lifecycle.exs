defmodule Pepe.Repo.Migrations.CreateSkillLifecycle do
  use Ecto.Migration

  def change do
    # One row per skill that anything has ever recorded about: who owns it (managed = written by
    # an agent, or handed over with `pepe skill adopt`), whether a human pinned it, where it sits
    # in the active/stale/archived lifecycle, and how much it is actually used.
    create table(:skill_stats, primary_key: false) do
      add :name, :string, primary_key: true
      add :managed, :boolean, null: false, default: false
      add :created_by, :string
      add :state, :string, null: false, default: "active"
      add :pinned, :boolean, null: false, default: false
      add :view_count, :integer, null: false, default: 0
      add :use_count, :integer, null: false, default: 0
      add :patch_count, :integer, null: false, default: 0
      add :fail_count, :integer, null: false, default: 0
      add :created_at, :integer, null: false
      add :last_viewed_at, :integer
      add :last_used_at, :integer
      add :last_patched_at, :integer
      add :state_changed_at, :integer
    end

    create index(:skill_stats, [:state])

    # The audit trail: every change to a skill, and who made it (an agent, the background
    # review, the curator, a person at the CLI or dashboard).
    create table(:skill_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :at, :integer, null: false
      add :skill, :string, null: false
      add :action, :string, null: false
      add :actor, :string, null: false
      add :detail, :text
    end

    create index(:skill_events, [:skill, :at])
    create index(:skill_events, [:at])
  end
end
