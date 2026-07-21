defmodule Pepe.Usage.MessageEvent do
  @moduledoc """
  One row of `Pepe.Usage.Messages` - a customer-originated message counted toward a
  project's monthly cap, or a reset marker. See that module's moduledoc.
  """

  use Ecto.Schema

  schema "message_events" do
    field :project, :string
    field :at, :integer
    field :reset, :boolean, default: false
  end
end
