defmodule Pepe.Repo.Migrations.CreatePendingApprovals do
  use Ecto.Migration

  def change do
    create table(:pending_approvals, primary_key: false) do
      add :id, :string, primary_key: true
      add :tool, :string, null: false
      add :args, :map, default: %{}
      add :session_key, :string
      add :agent, :string
      add :origin, :map, default: %{}
      add :grant, :string
      add :also_grant, :string
      add :tainted, :boolean, null: false, default: false
      # pending | approved | denied | expired
      add :status, :string, null: false, default: "pending"
      add :reason, :text
      add :created_at, :integer
      add :expires_at, :integer
      add :resolved_at, :integer
    end

    create index(:pending_approvals, [:status, :expires_at])
    create index(:pending_approvals, [:session_key])
  end
end
