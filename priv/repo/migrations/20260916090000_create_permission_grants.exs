defmodule Pepe.Repo.Migrations.CreatePermissionGrants do
  use Ecto.Migration

  def change do
    create table(:permission_grants, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent, :string, null: false
      add :grant, :string, null: false
      add :granted_by, :string
      add :source, :string, null: false
      add :reason, :text
      add :created_at, :integer, null: false
      add :revoked_at, :integer
      add :revoked_by, :string
    end

    create index(:permission_grants, [:agent, :revoked_at])
  end
end
