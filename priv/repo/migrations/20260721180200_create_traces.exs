defmodule Pepe.Repo.Migrations.CreateTraces do
  use Ecto.Migration

  def change do
    create table(:traces, primary_key: false) do
      add :id, :string, primary_key: true
      add :scope, :string, null: false
      add :at, :integer, null: false
      add :agent, :string
      add :session, :string
      add :source, :string
      add :prompt, :text
      add :ms, :integer
      add :outcome, :map, default: %{}
      # Written once (finish/1), read together (get/2) - never queried on individual
      # fields, so one column is the right shape, not a child table.
      add :events, {:array, :map}, default: []
    end

    # recent/2's `ORDER BY at DESC LIMIT`, and trim/1's oldest-N delete.
    create index(:traces, [:scope, :at])
    create index(:traces, [:scope])
  end
end
