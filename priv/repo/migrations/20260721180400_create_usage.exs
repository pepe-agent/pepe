defmodule Pepe.Repo.Migrations.CreateUsage do
  use Ecto.Migration

  def change do
    create table(:usage_entries) do
      add :project, :string, null: false
      add :at, :integer, null: false
      add :agent, :string
      add :model, :string
      add :in, :integer, null: false, default: 0
      add :out, :integer, null: false, default: 0
      add :sub, :boolean, null: false, default: false
      add :cached, :integer
    end

    # Bounds a bucket-window query in Pepe.Usage.summary/3 and month_to_date/1 to a real
    # index range scan regardless of how much history a project accumulates - the actual
    # point of moving this off "read every month's file ever written".
    create index(:usage_entries, [:project, :at])
    create index(:usage_entries, [:project])

    create table(:message_events) do
      add :project, :string, null: false
      add :at, :integer, null: false
      add :reset, :boolean, null: false, default: false
    end

    create index(:message_events, [:project, :at])
  end
end
