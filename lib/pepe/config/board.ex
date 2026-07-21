defmodule Pepe.Config.Board do
  @moduledoc """
  A board: a named, project-scoped container of `Pepe.Config.BoardCard`s that agents (and
  humans) move through a status pipeline; see `Pepe.Board`.

  Backed by `Pepe.Repo` (SQLite), not `config.json` - see that module's moduledoc.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # `id` is `Pepe.Project.handle(project, name)`: unlike agents, a board has no separate
  # rename-safe internal id; that indirection is overkill here.
  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "boards" do
    # The owning project (nil = root scope), same meaning as `Pepe.Config.Agent.project`.
    field :project, :string
    field :name, :string
    # Whether a `ready` card with an assignee fires on its own (the scheduler claims and
    # dispatches it) or only ever moves to `running` via an explicit `claim`: human, on
    # the dashboard, or an agent via the `board` tool. Off by default: an operator opts a
    # board into unattended dispatch deliberately, the same posture as every other
    # autonomy switch in Pepe (`midrun_fold`, `trust_untrusted_content`, ...).
    field :auto_dispatch, :boolean, default: false
    # Seconds a claim may sit in `running` before the scheduler treats it as stalled and
    # blocks the card (see `Pepe.Board.Scheduler`). 0 or nil = never auto-block on
    # timeout: only an explicit `complete`/`block` (or a crash, caught separately) ends
    # the claim.
    field :claim_timeout_s, :integer, default: 1800
  end

  @type t :: %__MODULE__{}

  @fields ~w(id project name auto_dispatch claim_timeout_s)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(board, attrs), do: cast(board, attrs, @fields)

  @doc "Parse a raw config.json map (the pre-migration on-disk shape) into a changeset."
  @spec from_map(map()) :: Ecto.Changeset.t()
  def from_map(map) when is_map(map) do
    changeset(%__MODULE__{}, %{
      id: map["id"],
      project: map["project"],
      name: map["name"],
      auto_dispatch: Map.get(map, "auto_dispatch", false),
      claim_timeout_s: Map.get(map, "claim_timeout_s", 1800)
    })
  end
end
