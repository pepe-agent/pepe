defmodule Pepe.Skills.Event do
  @moduledoc """
  One entry in the skills audit trail: what happened to which skill, and who did it.
  Written by `Pepe.Skills.Ledger`, read back by `pepe skill log` and the dashboard.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "skill_events" do
    field :at, :integer
    field :skill, :string
    field :action, :string
    field :actor, :string
    field :detail, :string
  end

  @type t :: %__MODULE__{}

  @fields ~w(id at skill action actor detail)a

  @doc "Build a changeset over the castable fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:id, :at, :skill, :action, :actor])
  end
end
