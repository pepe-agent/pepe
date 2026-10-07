defmodule Pepe.Repo.Migrations.CreateSeenChannels do
  use Ecto.Migration

  def change do
    # Every channel, group or direct message a connection has heard from: one row per
    # (connection, channel id), created the first time a message arrives there and refreshed
    # as more come in. `connection` is a webhook slug or a Telegram bot name; `kind` is "dm" or
    # "group" when the provider could tell, `name` a display name when one came cheaply.
    create table(:seen_channels) do
      add :connection, :string, null: false
      add :provider, :string, null: false
      add :channel, :string, null: false
      add :name, :string
      add :kind, :string
      add :first_seen, :integer, null: false
      add :last_seen, :integer, null: false
    end

    create unique_index(:seen_channels, [:connection, :channel])
  end
end
