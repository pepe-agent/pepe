defmodule Pepe.Config.BoardCard do
  @moduledoc """
  A card on a `Pepe.Config.Board`: one unit of work moving through a status pipeline
  (`triage → todo → ready → running → done | blocked → archived`); see `Pepe.Board` for the
  transition rules and `Pepe.Board.Scheduler` for what drives it.

  `triage` exists in the pipeline but a new card is never put there automatically: it's a
  spot to manually park something not yet ready to be worked (v1 has no auto-decomposer to
  promote it out again), not the default landing status. `create_card/1` starts a card at
  `todo` unless a caller explicitly asks for `triage`.
  """

  @derive Jason.Encoder
  defstruct id: nil,
            # The owning board's id (`Pepe.Config.Board.id`).
            board: nil,
            title: nil,
            body: nil,
            # The agent handle responsible for this card. Required for the scheduler to ever
            # auto-dispatch it (see `Pepe.Board.due_for_dispatch/1`); a manual `claim` works
            # without one too, naming the claimant directly.
            assignee: nil,
            status: "todo",
            # Sort key among `ready` cards competing for dispatch: higher first. Not a real
            # priority queue: just `{-priority, created_at}` ordering on each tick.
            priority: 0,
            # Same-board card ids this one waits on: only `done` (never `archived`) satisfies
            # one. Same-board only; a cross-board dependency is rejected at write time.
            depends_on: [],
            # Overrides the owning board's `auto_dispatch` for this one card: nil (the
            # default) inherits the board's setting; `true`/`false` forces it regardless.
            # A manual `claim` always works either way; this only decides whether the
            # scheduler's own tick fires the card on its own. See Pepe.Board.effective_auto_dispatch?/2.
            auto_dispatch: nil,
            # Who currently holds the claim: a session key (`"board:<board>:<card>"` for a
            # dispatched run) or a fixed literal (`"dashboard"` for a manual human claim). nil
            # when not `running`.
            claimed_by: nil,
            claimed_at: nil,
            # Set on any `running → blocked` transition (explicit `block`, a timeout, or a
            # dispatch that ended without calling `complete`/`block`): always present on a
            # blocked card, so the dashboard/tool never has to guess why.
            block_reason: nil,
            created_at: nil,
            updated_at: nil

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
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
    }
  end
end
