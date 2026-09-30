defmodule Pepe.Repo.Migrations.CreateDrafts do
  use Ecto.Migration

  def change do
    # An edit in progress on a dashboard form: saved as the operator types, applied to the real
    # config only when they press Save. One row per thing being edited (`kind` is the screen,
    # `key` the record, or "new" for one not created yet), holding the form's state as JSON.
    create table(:drafts) do
      add :kind, :string, null: false
      add :key, :string, null: false
      add :data, :map, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:drafts, [:kind, :key])
  end
end
