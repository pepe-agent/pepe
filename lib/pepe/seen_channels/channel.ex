defmodule Pepe.SeenChannels.Channel do
  @moduledoc """
  One place a connection has heard from: a channel, a group, a forum topic or a direct
  message, keyed by the connection and the platform's own id for it. See `Pepe.SeenChannels`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "seen_channels" do
    field :connection, :string
    field :provider, :string
    field :channel, :string
    field :name, :string
    field :label, :string
    field :kind, :string
    field :first_seen, :integer
    field :last_seen, :integer
  end
end
