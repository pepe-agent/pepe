defmodule Pepe.Config.Journal.Entry do
  @moduledoc """
  One row of the config journal - see `Pepe.Config.Journal`'s moduledoc for what this
  tracks and, more importantly, what it deliberately never records.
  """

  use Ecto.Schema

  schema "config_journal_entries" do
    field :at, :integer
    field :source, :string
    field :changed, {:array, :string}
    field :external, :boolean, default: false
  end
end
