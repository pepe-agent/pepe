defmodule Pepe.Repo.Migrations.CreateConfigJournalEntries do
  use Ecto.Migration

  def change do
    create table(:config_journal_entries) do
      add :at, :integer, null: false
      add :source, :string, null: false
      add :changed, {:array, :string}, null: false, default: []
      add :external, :boolean, null: false, default: false
    end
  end
end
