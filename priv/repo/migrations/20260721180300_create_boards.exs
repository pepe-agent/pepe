defmodule Pepe.Repo.Migrations.CreateBoards do
  use Ecto.Migration

  def change do
    create table(:boards, primary_key: false) do
      add :id, :string, primary_key: true
      add :project, :string
      add :name, :string
      add :auto_dispatch, :boolean, null: false, default: false
      add :claim_timeout_s, :integer, null: false, default: 1800
    end

    create table(:board_cards, primary_key: false) do
      add :id, :string, primary_key: true
      # Ecto/SQLite doesn't auto-index a FK column - the explicit index below is what
      # makes board_cards_for/1 (WHERE board = ?) an index-range scan, not a table scan.
      add :board, references(:boards, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :title, :text
      add :body, :text
      add :assignee, :string
      add :status, :string, null: false, default: "todo"
      add :priority, :integer, null: false, default: 0
      add :depends_on, {:array, :string}, default: []
      # nil = inherit the board's own auto_dispatch; true/false overrides it.
      add :auto_dispatch, :boolean
      add :claimed_by, :string
      add :claimed_at, :integer
      add :block_reason, :text
      add :created_at, :integer
      add :updated_at, :integer
    end

    create index(:board_cards, [:board])
    create index(:board_cards, [:status])
  end
end
