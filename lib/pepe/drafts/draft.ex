defmodule Pepe.Drafts.Draft do
  @moduledoc """
  One unpublished edit: the state of a dashboard form, kept until the operator saves or
  discards it. See `Pepe.Drafts`.
  """

  use Ecto.Schema

  schema "drafts" do
    field :kind, :string
    field :key, :string
    field :data, :map
    field :updated_at, :integer
  end
end
