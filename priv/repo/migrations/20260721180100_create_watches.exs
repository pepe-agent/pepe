defmodule Pepe.Repo.Migrations.CreateWatches do
  use Ecto.Migration

  def change do
    create table(:watches, primary_key: false) do
      add :id, :string, primary_key: true
      add :description, :text
      add :agent, :string
      add :trigger, :map, default: %{}
      add :on_fire, :map, default: %{}
      add :origin, :map, default: %{}
      add :interval_s, :integer, null: false, default: 120
      add :max_checks, :integer, null: false, default: 720
      add :checks, :integer, null: false, default: 0
      add :state, :string, null: false, default: "pending"
      add :created, :integer
      add :last_check, :integer
      add :next_check, :integer
      add :last_error, :text
      add :pending_delivery, :text
    end

    # Future-facing, mirroring commitments' own [:state, :due_at] index: not yet wired
    # into the scheduler's tick query (Config.watches/0 still loads every row and filters
    # in memory), but provisioned ahead of that rewrite rather than added later.
    create index(:watches, [:state, :next_check])
    create index(:watches, [:agent])
  end
end
