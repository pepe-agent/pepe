defmodule Pepe.Permissions.GrantRecord do
  @moduledoc """
  One "always allow" event: which agent, which `Pepe.Permissions.Grant` string, who/where
  it came from, and (once revoked) who undid it and when. See `Pepe.Permissions.Grants`
  for how these are written and revoked.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # App-generated string ids (short random hex), not Ecto's autoincrement integer - a human
  # has to type this id into a CLI command, same convention as Pepe.Permissions.PendingApproval.
  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "permission_grants" do
    field :agent, :string
    field :grant, :string
    field :granted_by, :string
    field :source, :string
    field :reason, :string
    field :created_at, :integer
    field :revoked_at, :integer
    field :revoked_by, :string
  end

  @type t :: %__MODULE__{}

  @fields ~w(id agent grant granted_by source reason created_at revoked_at revoked_by)a

  @doc "Build a changeset over the castable fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant_record, attrs) do
    grant_record
    |> cast(attrs, @fields)
    |> validate_required([:id, :agent, :grant, :source, :created_at])
  end
end
