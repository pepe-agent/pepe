defmodule Pepe.SeenPeople.Person do
  @moduledoc """
  One person who has written in one channel of a connection, keyed by the connection, the
  channel and the platform's own id for them. See `Pepe.SeenPeople`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "seen_people" do
    field :connection, :string
    field :channel, :string
    field :person, :string
    field :name, :string
    field :label, :string
    field :first_seen, :integer
    field :last_seen, :integer
  end
end
