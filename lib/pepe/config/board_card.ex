defmodule Pepe.Config.BoardCard do
  @moduledoc """
  A card on a `Pepe.Config.Board`: one unit of work moving through a status pipeline
  (`triage → todo → ready → running → done | blocked → archived`); see `Pepe.Board` for the
  transition rules and `Pepe.Board.Scheduler` for what drives it.

  `triage` exists in the pipeline but a new card is never put there automatically: it's a
  spot to manually park something not yet ready to be worked (v1 has no auto-decomposer to
  promote it out again), not the default landing status. `create_card/1` starts a card at
  `todo` unless a caller explicitly asks for `triage`.

  Backed by `Pepe.Repo` (SQLite), not `config.json` - see that module's moduledoc. `board`
  is a real foreign key (`references(:boards, ...)`, `on_delete: :delete_all`): deleting a
  board cascades to its cards at the database level.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "board_cards" do
    # The owning board's id (`Pepe.Config.Board.id`).
    field :board, :string
    field :title, :string
    field :body, :string
    # The agent handle responsible for this card. Required for the scheduler to ever
    # auto-dispatch it (see `Pepe.Board.due_for_dispatch/1`); a manual `claim` works
    # without one too, naming the claimant directly.
    field :assignee, :string
    field :status, :string, default: "todo"
    # Sort key among `ready` cards competing for dispatch: higher first. Not a real
    # priority queue: just `{-priority, created_at}` ordering on each tick.
    field :priority, :integer, default: 0
    # Same-board card ids this one waits on: only `done` (never `archived`) satisfies
    # one. Same-board only; a cross-board dependency is rejected at write time.
    field :depends_on, {:array, :string}, default: []
    # Overrides the owning board's `auto_dispatch` for this one card: nil (the
    # default) inherits the board's setting; `true`/`false` forces it regardless.
    # A manual `claim` always works either way; this only decides whether the
    # scheduler's own tick fires the card on its own. See Pepe.Board.effective_auto_dispatch?/2.
    field :auto_dispatch, :boolean
    # Who currently holds the claim: a session key (`"board:<board>:<card>"` for a
    # dispatched run) or a fixed literal (`"dashboard"` for a manual human claim). nil
    # when not `running`.
    field :claimed_by, :string
    field :claimed_at, :integer
    # Bumped by `Pepe.Board.heartbeat/2` while a long-running claim is still alive - kept
    # separate from `claimed_at`, which doubles as the claim's identity token (see
    # `Pepe.Board.block_if_still_running/3`). nil until the first heartbeat.
    field :heartbeated_at, :integer
    # Set on any `running → blocked` transition (explicit `block`, a timeout, or a
    # dispatch that ended without calling `complete`/`block`): always present on a
    # blocked card, so the dashboard/tool never has to guess why.
    field :block_reason, :string
    field :created_at, :integer
    field :updated_at, :integer
  end

  @type t :: %__MODULE__{}

  @fields ~w(id board title body assignee status priority depends_on auto_dispatch
             claimed_by claimed_at heartbeated_at block_reason created_at updated_at)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(card, attrs), do: cast(card, attrs, @fields)

  @doc "Parse a raw config.json map (the pre-migration on-disk shape) into a changeset."
  @spec from_map(map()) :: Ecto.Changeset.t()
  def from_map(map) when is_map(map) do
    changeset(%__MODULE__{}, %{
      id: map["id"],
      board: map["board"],
      title: map["title"],
      body: map["body"],
      assignee: map["assignee"],
      status: map["status"] || "triage",
      priority: Map.get(map, "priority", 0),
      depends_on: map["depends_on"] || [],
      auto_dispatch: Map.get(map, "auto_dispatch"),
      claimed_by: map["claimed_by"],
      claimed_at: map["claimed_at"],
      block_reason: map["block_reason"],
      created_at: map["created_at"],
      updated_at: map["updated_at"]
    })
  end
end
