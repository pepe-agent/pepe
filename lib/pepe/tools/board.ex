defmodule Pepe.Tools.Board do
  @moduledoc """
  Create, track, and work cards on a **board**: a durable, resumable queue of
  work items (not a sales/CRM pipeline) with dependencies between them, for
  handing off multi-step or long-running work between agents and humans. See
  `Pepe.Board` for the full state machine.

  `complete`/`block`/`comment` don't need a `card_id` when called from a session
  the board itself dispatched (an `auto_dispatch` board claiming and running its
  assignee): it's inferred from that session automatically. Called from anywhere
  else (a human's own chat, one agent managing another's board), pass `card_id`.

  It's a risky tool (not on the always-safe list, so it goes through the human
  permission gate unless pre-approved), same posture as `manage_agent` and
  `schedule_task`. **An agent used as a board assignee on an `auto_dispatch`
  board needs `auto_approve` covering `"board"`**: its dispatched session has no
  human attached to approve anything, the same rule a cron's unattended run
  already lives under. Without it, every `complete`/`block`/`comment` call is
  silently denied and the card just sits until the board's `claim_timeout_s`
  blocks it.

  `archive(force: true)` on a `running` card is deliberately NOT exposed here:
  only the dashboard/CLI can force-archive work still in flight.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Board
  alias Pepe.Config
  alias Pepe.Config.BoardCard

  @impl true
  def name, do: "board"

  @impl true
  def spec do
    function(
      "board",
      """
      Track multi-step or handed-off work as cards moving through a status pipeline \
      (todo -> ready -> running -> done/blocked -> archived), with dependencies between \
      cards. Not a sales/CRM tool: a card is a work item, not a contact or a lead.

      If you're setting up a board meant to fire on its own (`auto_dispatch: true`), tell \
      the user the assignee agent needs `board` in its auto_approve list: a card dispatched \
      that way has no human attached to approve anything, so complete/block/comment would \
      otherwise just be denied and the card would sit until it times out.

      actions:
      - list_boards: show all boards.
      - create_board: needs `name`; optional `project` (root/default if omitted), \
        `auto_dispatch` (true = a ready card with an assignee fires on its own; \
        false, the default = only an explicit `claim` starts it), `claim_timeout_s` \
        (how long a claim may run before it's treated as stalled and blocked; omit \
        for the default).
      - list_cards: needs `board_id`; optional `status` to filter.
      - show_card: needs `card_id`.
      - create_card: needs `board_id`, `title`; optional `body`, `assignee` (an agent \
        handle), `priority` (higher = dispatched first), `depends_on` (card ids on the \
        SAME board that must be `done` first), `auto_dispatch` (overrides the board's own \
        setting for just this card: true/false; omit to inherit the board's setting).
      - link: add a dependency, needs `card_id`, `depends_on_id`.
      - force_ready: move a `todo` card to `ready`, skipping its dependency check; \
        needs `card_id`.
      - set_auto_dispatch: override (or clear) whether THIS card fires on its own, \
        regardless of its board's setting; needs `card_id`, `value` ("on"/"off"/"inherit").
      - claim: `ready` -> `running`, needs `card_id`.
      - complete: `running` -> `done`, `card_id` optional (inferred, see above); \
        optional `text` (a short result note).
      - block: `running` -> `blocked`, `card_id` optional (inferred); needs `text` \
        (why: "waiting on X", "needs a human decision", ...).
      - heartbeat: still working a `running` claim - resets its stall-timeout clock so \
        the board doesn't treat genuinely ongoing work as stalled. `card_id` optional \
        (inferred). Call this periodically during a task that runs longer than the \
        board's claim_timeout_s, not on every step - it's a liveness signal, not \
        progress logging (use comment for that).
      - unblock: `blocked` -> `ready`, clearing the claim; needs `card_id`.
      - comment: leave a note on a card's history without changing its status; \
        `card_id` optional (inferred); needs `text`.
      - archive: needs `card_id`. Refuses a `running` card (ask the user to do that \
        from the dashboard if it genuinely needs to be cut short).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" =>
              ~w(list_boards create_board list_cards show_card create_card link force_ready set_auto_dispatch claim complete block heartbeat unblock comment archive),
            "description" => "What to do."
          },
          "board_id" => %{"type" => "string", "description" => "For create_card/list_cards."},
          "card_id" => %{"type" => "string", "description" => "The card to act on. Optional for complete/block/comment: see above."},
          "project" => %{"type" => "string", "description" => "For create_board. Omit for the root/default project."},
          "name" => %{"type" => "string", "description" => "Board name, for create_board."},
          "auto_dispatch" => %{
            "type" => "boolean",
            "description" => "For create_board (the board's own default) or create_card (a per-card override of its board's setting)."
          },
          "claim_timeout_s" => %{"type" => "integer", "description" => "For create_board."},
          "title" => %{"type" => "string", "description" => "Card title, for create_card."},
          "body" => %{"type" => "string", "description" => "Card body/instructions, for create_card."},
          "assignee" => %{"type" => "string", "description" => "Agent handle responsible for the card, for create_card."},
          "priority" => %{"type" => "integer", "description" => "For create_card. Higher is dispatched first."},
          "depends_on" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Card ids this one waits on, for create_card."
          },
          "depends_on_id" => %{"type" => "string", "description" => "The dependency card id, for link."},
          "status" => %{"type" => "string", "description" => "Status filter, for list_cards."},
          "text" => %{"type" => "string", "description" => "For complete (result note), block (reason, required), or comment (required)."},
          "value" => %{"type" => "string", "enum" => ~w(on off inherit), "description" => "For set_auto_dispatch."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args, ctx), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "board needs an `action`"}

  defp dispatch("list_boards", _args, _ctx) do
    case Config.boards() do
      [] -> {:ok, "No boards yet."}
      boards -> {:ok, Enum.map_join(boards, "\n", &describe_board/1)}
    end
  end

  defp dispatch("create_board", args, _ctx) do
    attrs = %{
      project: blank(args["project"]),
      name: args["name"],
      auto_dispatch: args["auto_dispatch"] || false,
      claim_timeout_s: args["claim_timeout_s"]
    }

    case Board.create_board(attrs) do
      {:ok, board} -> {:ok, "Created board #{board.id}."}
      {:error, :already_exists} -> {:error, "a board named #{args["name"]} already exists there"}
    end
  end

  defp dispatch("list_cards", args, _ctx) do
    with {:ok, board_id} <- require_arg(args, "board_id") do
      cards = Config.board_cards_for(board_id)
      cards = if status = args["status"], do: Enum.filter(cards, &(&1.status == status)), else: cards
      if cards == [], do: {:ok, "No cards."}, else: {:ok, Enum.map_join(cards, "\n", &describe_card_line/1)}
    end
  end

  defp dispatch("show_card", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id"),
         %BoardCard{} = card <- Config.get_board_card(card_id) do
      {:ok, describe_card(card)}
    else
      nil -> {:error, "no such card"}
      other -> other
    end
  end

  defp dispatch("create_card", args, _ctx) do
    attrs = %{
      board: args["board_id"],
      title: args["title"],
      body: args["body"],
      assignee: blank(args["assignee"]),
      priority: args["priority"],
      depends_on: args["depends_on"] || [],
      # Map.get, not `||`: `auto_dispatch: false` is a real, meaningful override (see
      # Pepe.Board.effective_auto_dispatch?/2), not the same as omitting it.
      auto_dispatch: Map.get(args, "auto_dispatch")
    }

    case Board.create_card(attrs) do
      {:ok, card} -> {:ok, "Created card #{card.id} on #{card.board}."}
      {:error, :board_not_found} -> {:error, "no such board: #{args["board_id"]}"}
      {:error, :invalid_dependency} -> {:error, "depends_on must name existing cards on the same board, with no cycle"}
      {:error, reason} -> {:error, "could not create card: #{inspect(reason)}"}
    end
  end

  defp dispatch("link", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id"),
         {:ok, dep_id} <- require_arg(args, "depends_on_id") do
      case Board.link(card_id, dep_id) do
        {:ok, card} -> {:ok, "#{card.id} now depends on #{dep_id}."}
        {:error, :invalid_dependency} -> {:error, "that dependency doesn't exist, isn't on the same board, or would create a cycle"}
        {:error, reason} -> respond_error(reason)
      end
    end
  end

  defp dispatch("force_ready", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id"), do: respond_transition(Board.force_ready(card_id))
  end

  defp dispatch("set_auto_dispatch", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id"),
         {:ok, value} <- require_arg(args, "value"),
         {:ok, parsed} <- parse_tri_state(value) do
      respond_transition(Board.set_auto_dispatch(card_id, parsed))
    else
      {:error, :bad_value} -> {:error, ~s(value must be "on", "off", or "inherit")}
      other -> other
    end
  end

  defp dispatch("claim", args, ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id") do
      respond_transition(Board.claim(card_id, claimant(ctx)))
    end
  end

  defp dispatch("complete", args, ctx) do
    with {:ok, card_id} <- card_id_arg(args, ctx) do
      respond_transition(Board.complete(card_id, blank(args["text"])))
    end
  end

  defp dispatch("block", args, ctx) do
    with {:ok, card_id} <- card_id_arg(args, ctx),
         {:ok, reason} <- require_arg(args, "text") do
      respond_transition(Board.block(card_id, reason))
    end
  end

  defp dispatch("heartbeat", args, ctx) do
    with {:ok, card_id} <- card_id_arg(args, ctx) do
      case Board.heartbeat(card_id, claimant(ctx)) do
        {:ok, _card} -> {:ok, "#{card_id} heartbeat recorded."}
        {:error, :not_your_claim} -> {:error, "#{card_id} is claimed by someone else"}
        other -> respond_transition(other)
      end
    end
  end

  defp dispatch("unblock", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id"), do: respond_transition(Board.unblock(card_id))
  end

  defp dispatch("comment", args, ctx) do
    with {:ok, card_id} <- card_id_arg(args, ctx),
         {:ok, text} <- require_arg(args, "text") do
      case Board.comment(card_id, claimant(ctx), text) do
        :ok -> {:ok, "Comment added."}
        {:error, :not_found} -> {:error, "no such card"}
      end
    end
  end

  defp dispatch("archive", args, _ctx) do
    with {:ok, card_id} <- require_arg(args, "card_id") do
      case Board.archive(card_id) do
        {:ok, card} -> {:ok, "#{card.id} archived."}
        {:error, :running} -> {:error, "#{card_id} is running: ask the user to archive it from the dashboard if it needs to be cut short"}
        other -> respond_transition(other)
      end
    end
  end

  defp dispatch(other, _args, _ctx), do: {:error, "unknown or incomplete action: #{other}"}

  ###
  ### helpers
  ###

  defp require_arg(args, key) do
    case args[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing `#{key}`"}
    end
  end

  defp auto_dispatch_label(nil), do: "(inherits board setting)"
  defp auto_dispatch_label(true), do: "on (overridden for this card)"
  defp auto_dispatch_label(false), do: "off (overridden for this card)"

  defp parse_tri_state("on"), do: {:ok, true}
  defp parse_tri_state("off"), do: {:ok, false}
  defp parse_tri_state("inherit"), do: {:ok, nil}
  defp parse_tri_state(_), do: {:error, :bad_value}

  # `complete`/`block`/`comment` accept an explicit `card_id`, or infer it from a
  # session the board itself dispatched; see the moduledoc.
  defp card_id_arg(args, ctx) do
    case args["card_id"] || card_id_from_session_key(ctx[:session_key]) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing `card_id` (this session wasn't dispatched by a board, so it can't be inferred)"}
    end
  end

  defp card_id_from_session_key("board:" <> rest) do
    case String.split(rest, ":") do
      [_board, card_id] -> card_id
      _ -> nil
    end
  end

  defp card_id_from_session_key(_), do: nil

  defp claimant(ctx), do: (ctx[:agent] && ctx[:agent].name) || "unknown"

  defp respond_transition({:ok, card}), do: {:ok, "#{card.id} is now #{card.status}."}
  defp respond_transition({:error, reason}), do: respond_error(reason)

  defp respond_error({:unexpected_status, status}), do: {:error, "can't do that from status #{status}"}
  defp respond_error(:not_found), do: {:error, "no such card"}
  defp respond_error(:no_timeout), do: {:error, "this board has no claim_timeout_s configured"}
  defp respond_error(:conflict), do: {:error, "the card changed concurrently - try again"}
  defp respond_error(reason), do: {:error, inspect(reason)}

  defp describe_board(board) do
    "#{board.id} (auto_dispatch=#{board.auto_dispatch}, claim_timeout_s=#{board.claim_timeout_s || "off"})"
  end

  defp describe_card_line(card) do
    assignee = if card.assignee, do: " -> #{card.assignee}", else: ""
    "#{card.id} [#{card.status}]#{assignee} #{card.title}"
  end

  defp describe_card(card) do
    recent = Pepe.Board.Log.tail(card.id, 5) |> Enum.map_join("\n", &"  - #{&1["event"]}#{extra_summary(&1)}")

    """
    card: #{card.id}
    board: #{card.board}
    title: #{card.title}
    status: #{card.status}
    assignee: #{card.assignee || "(unassigned)"}
    auto_dispatch: #{auto_dispatch_label(card.auto_dispatch)}
    priority: #{card.priority}
    depends_on: #{if card.depends_on == [], do: "(none)", else: Enum.join(card.depends_on, ", ")}
    claimed_by: #{card.claimed_by || "(none)"}
    block_reason: #{card.block_reason || "(none)"}
    body: #{card.body}

    recent activity:
    #{if recent == "", do: "  (none)", else: recent}
    """
  end

  defp extra_summary(%{"text" => text}) when is_binary(text) and text != "", do: ": #{text}"
  defp extra_summary(%{"reason" => reason}) when is_binary(reason) and reason != "", do: ": #{reason}"
  defp extra_summary(_), do: ""

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(v), do: v
end
