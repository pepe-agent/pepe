defmodule Pepe.Repo.Migrations.CreateSeenPeople do
  use Ecto.Migration

  def change do
    # Every person who has written in a channel a connection has heard from: one row per
    # (connection, channel id, person id), created on their first message there and refreshed
    # as more come in, with a display name when the platform gave one. Bots and this app's own
    # messages are never recorded. What the trainer pickers on the Channels page offer.
    create table(:seen_people) do
      add :connection, :string, null: false
      add :channel, :string, null: false
      add :person, :string, null: false
      add :name, :string
      add :first_seen, :integer, null: false
      add :last_seen, :integer, null: false
    end

    create unique_index(:seen_people, [:connection, :channel, :person])
  end
end
