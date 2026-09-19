defmodule Pepe.Skills.Stat do
  @moduledoc """
  What Pepe knows *about* a skill, as opposed to what the skill says: whether it is
  **managed** (written by an agent, or handed over by a person with `pepe skill adopt`),
  whether a person **pinned** it, its lifecycle **state** (`active` / `stale` / `archived`),
  and how much it is used. See `Pepe.Skills.Stats` for how the counters move and
  `Pepe.Skills.Ownership` for how these fields, together with where the file lives,
  decide who may change it.

  `managed` is an opt-in policy flag, not proof of authorship: it is set when an agent
  creates the skill through `skill_manage`, and it is the *only* thing that lets the
  background review and the curator touch a skill on their own. A skill a person wrote
  never carries it, so it stays theirs however relevant the review thinks it is.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "skill_stats" do
    field :managed, :boolean, default: false
    field :created_by, :string
    field :state, :string, default: "active"
    field :pinned, :boolean, default: false
    field :view_count, :integer, default: 0
    field :use_count, :integer, default: 0
    field :patch_count, :integer, default: 0
    field :fail_count, :integer, default: 0
    field :created_at, :integer
    field :last_viewed_at, :integer
    field :last_used_at, :integer
    field :last_patched_at, :integer
    field :state_changed_at, :integer
  end

  @type t :: %__MODULE__{}

  @states ~w(active stale archived)

  @fields ~w(name managed created_by state pinned view_count use_count patch_count fail_count
             created_at last_viewed_at last_used_at last_patched_at state_changed_at)a

  @doc "The lifecycle states a skill can be in."
  def states, do: @states

  @doc "Build a changeset over the castable fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stat, attrs) do
    stat
    |> cast(attrs, @fields)
    |> validate_required([:name, :created_at])
    |> validate_inclusion(:state, @states)
  end

  @doc """
  The most recent moment a skill was actually put to work or changed (its last use, view
  or edit), falling back to when it was created - `nil` never happens for a stored row.
  This is the clock the curator's inactivity thresholds run on.
  """
  @spec last_activity_at(t()) :: integer()
  def last_activity_at(%__MODULE__{} = s) do
    [s.last_used_at, s.last_viewed_at, s.last_patched_at, s.created_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end
end
