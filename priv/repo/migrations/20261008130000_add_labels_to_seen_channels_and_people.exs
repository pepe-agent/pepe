defmodule Pepe.Repo.Migrations.AddLabelsToSeenChannelsAndPeople do
  use Ecto.Migration

  def change do
    # A name the operator typed for a channel or a person, kept apart from the provider's own
    # `name` so a later refresh of that never overwrites it. Display only: never used to match
    # or authorize anything. A person's label is the same on every row of that person within
    # the connection (see Pepe.SeenPeople.put_label/3).
    alter table(:seen_channels) do
      add :label, :string
    end

    alter table(:seen_people) do
      add :label, :string
    end
  end
end
