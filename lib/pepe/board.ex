defmodule Pepe.Board do
  @moduledoc """
  Card lifecycle: creating, linking dependencies, claiming, and moving a card through its
  status pipeline (`triage → todo → ready → running → done | blocked → archived`).

  Every state-changing operation here is atomic against `Pepe.Repo` directly, by
  precondition shape:

    * A precondition on the card's own columns (`claim`, `complete`, `block`, `unblock`,
      `force_ready`, `unarchive`, `archive/2`, `reclaim_if_timed_out/2`) is one
      conditional `UPDATE ... WHERE id = ? AND <precondition>` - the returned row count
      *is* the atomic result (1 = won, 0 = lost), no transaction needed.
    * A precondition that reads *other* cards (`link/2`, `create_card/1`,
      `promote_if_ready/1` - the acyclic-dependency check walks the whole board's graph)
      runs inside `Pepe.Repo.transaction/1`: read, decide, write, all in one transaction.
    * `create_board/1`'s precondition ("this id isn't taken yet") is a single
      `INSERT ... ON CONFLICT DO NOTHING`, whose returned row count is the same kind of
      atomic signal as the conditional-UPDATE case.

  This replaces the old `Pepe.Config.update_cas/1`-based design this module used to run
  on: the same "read and write happen atomically, no separate get-then-write" guarantee,
  expressed against the database instead of a whole-file compare-and-swap.
  `update_cas/1` itself is still very much alive - `put_model`, `put_agent`, and
  `update_telegram_bot` all still go through it - just no longer for cards.

  `Pepe.Board.Scheduler` is the tick-driven caller of `promote_if_ready/1`,
  `reclaim_if_timed_out/2`, and dispatch; `Pepe.Tools.Board` and the dashboard are the other
  two callers, for the same functions. There is no separate "coordinator" process gating
  these, on purpose (see the scheduler's moduledoc for why).
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Config.Board
  alias Pepe.Config.BoardCard
  alias Pepe.Repo

  @doc "PubSub topic carrying `{:board_event, card_id, event}` for every card change."
  def events_topic, do: "boards:events"

  @doc "Create a board. Fails if `project`/`name` already identify one."
  @spec create_board(map()) :: {:ok, Board.t()} | {:error, term()}
  def create_board(attrs) do
    project = fetch(attrs, :project)
    name = fetch(attrs, :name)
    id = Pepe.Project.handle(project, name)

    row = %{
      id: id,
      project: project,
      name: name,
      auto_dispatch: fetch(attrs, :auto_dispatch) || false,
      claim_timeout_s: fetch(attrs, :claim_timeout_s) || 1800
    }

    # ON CONFLICT DO NOTHING's returned row count is the atomic "did this id already
    # exist" signal - same idiom the migration modules already use, no read-then-write
    # gap at all (stronger than a transaction-wrapped existence check would be).
    case Repo.insert_all(Board, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, struct(Board, row)}
      {0, _} -> {:error, :already_exists}
    end
  end

  @doc """
  Delete a board. Refuses unless it has no cards (`force: true` cascades: deletes the cards
  and their `Pepe.Board.Log` files too).
  """
  @spec delete_board(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_board(id, opts \\ []) do
    card_ids = Config.board_cards_for(id) |> Enum.map(& &1.id)

    case Config.delete_board(id, opts) do
      :ok ->
        if Keyword.get(opts, :force, false), do: Enum.each(card_ids, &Pepe.Board.Log.delete/1)
        :ok

      other ->
        other
    end
  end

  @doc "Create a card on `board`. Validates dependencies are same-board and acyclic."
  @spec create_card(map()) :: {:ok, BoardCard.t()} | {:error, term()}
  def create_card(attrs) do
    board_id = fetch(attrs, :board)
    depends_on = fetch(attrs, :depends_on) || []
    id = new_card_id()

    Repo.transaction(fn ->
      cond do
        is_nil(Repo.get(Board, board_id)) ->
          Repo.rollback(:board_not_found)

        not valid_deps?(board_id, id, depends_on) ->
          Repo.rollback(:invalid_dependency)

        true ->
          ts = now()

          changeset =
            BoardCard.changeset(%BoardCard{}, %{
              id: id,
              board: board_id,
              title: fetch(attrs, :title),
              body: fetch(attrs, :body),
              assignee: fetch(attrs, :assignee),
              status: fetch(attrs, :status) || "todo",
              priority: fetch(attrs, :priority) || 0,
              depends_on: depends_on,
              auto_dispatch: fetch(attrs, :auto_dispatch),
              created_at: ts,
              updated_at: ts
            })

          Repo.insert!(changeset)
      end
    end)
    |> tap_ok(fn card -> log_event(card.id, "created", %{}) end)
  end

  @doc "Add a dependency edge to an existing card. Same validation as `create_card/1`."
  @spec link(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def link(card_id, depends_on_id) do
    Repo.transaction(fn ->
      case Repo.get(BoardCard, card_id) do
        nil ->
          Repo.rollback(:not_found)

        card ->
          new_deps = Enum.uniq([depends_on_id | card.depends_on])

          if valid_deps?(card.board, card_id, new_deps) do
            card |> BoardCard.changeset(%{depends_on: new_deps, updated_at: now()}) |> Repo.update!()
          else
            Repo.rollback(:invalid_dependency)
          end
      end
    end)
    |> tap_ok(fn _card -> log_event(card_id, "linked", %{"depends_on" => depends_on_id}) end)
  end

  @doc """
  Override (`true`/`false`) or clear (`nil`) this card's own `auto_dispatch`, regardless
  of its board's setting; see `effective_auto_dispatch?/2`. Never touches its status. No
  precondition to check, so this is a plain unconditional update.
  """
  @spec set_auto_dispatch(String.t(), boolean() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def set_auto_dispatch(card_id, value) when is_boolean(value) or is_nil(value) do
    update_unconditionally(card_id, auto_dispatch: value)
    |> tap_ok(fn _card -> log_event(card_id, "auto_dispatch_set", %{"value" => value}) end)
  end

  @doc "`ready → running`. Works whether or not the board has `auto_dispatch` on."
  @spec claim(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def claim(card_id, claimant) do
    transition(card_id, "ready", status: "running", claimed_by: claimant, claimed_at: now())
    |> tap_ok(fn _card -> log_event(card_id, "claimed", %{"by" => claimant}) end)
  end

  @doc "`running → done`."
  @spec complete(String.t(), String.t() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def complete(card_id, result \\ nil) do
    transition(card_id, "running", status: "done")
    |> tap_ok(fn _card -> log_event(card_id, "completed", %{"result" => result}) end)
  end

  @doc "`running → blocked`, with a reason."
  @spec block(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def block(card_id, reason) do
    transition(card_id, "running", status: "blocked", block_reason: reason)
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => reason}) end)
  end

  @doc """
  If still `running` under the same claim (`claimed_by`/`claimed_at` both match what the
  caller captured when it dispatched this run), block it: the dispatch working on it ended
  without calling `complete`/`block`. The claim pair is what makes this safe against the
  ABA race a bare status check would miss - the card could have been blocked-on-timeout,
  unblocked, and reclaimed by an unrelated dispatch in between, and a status-only check
  would then block that *new* claim instead of a no-op. `claimed_at` alone isn't enough:
  it's second-granularity (the same precision as every other timestamp here), so two
  claims landing in the same wall-clock second would otherwise collide.
  """
  @spec block_if_still_running(String.t(), String.t(), integer()) :: {:ok, BoardCard.t()} | {:error, term()}
  def block_if_still_running(card_id, claimed_by, claimed_at) do
    reason = "worker exited without completing"

    query =
      from(c in BoardCard,
        where: c.id == ^card_id and c.status == "running" and c.claimed_by == ^claimed_by and c.claimed_at == ^claimed_at
      )

    case update_and_get(query, [status: "blocked", block_reason: reason], card_id) do
      {:ok, card} -> {:ok, card}
      :miss -> {:error, :stale_claim}
    end
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => reason}) end)
  end

  @doc "`blocked → ready`, clearing the claim."
  @spec unblock(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def unblock(card_id) do
    transition(card_id, "blocked", status: "ready", claimed_by: nil, claimed_at: nil, block_reason: nil)
    |> tap_ok(fn _card -> log_event(card_id, "unblocked", %{}) end)
  end

  @doc "`todo → ready`, bypassing the dependency gate."
  @spec force_ready(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def force_ready(card_id) do
    transition(card_id, "todo", status: "ready")
    |> tap_ok(fn _card -> log_event(card_id, "forced_ready", %{}) end)
  end

  @doc """
  Archive a card. Refuses on a `running` card unless `force: true` (the dashboard/CLI path -
  deliberately not exposed through `Pepe.Tools.Board`, see its moduledoc).
  """
  @spec archive(String.t(), keyword()) :: {:ok, BoardCard.t()} | {:error, term()}
  def archive(card_id, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    # Not a fixed from_status (archive/2 has two independent preconditions, not one status
    # transition): the WHERE clause itself is what makes "not already archived, and not
    # running unless forced" atomic, same as every other transition here.
    query =
      if force? do
        from(c in BoardCard, where: c.id == ^card_id and c.status != "archived")
      else
        from(c in BoardCard, where: c.id == ^card_id and c.status not in ["archived", "running"])
      end

    case update_and_get(query, [status: "archived"], card_id) do
      {:ok, card} -> {:ok, card}
      :miss -> archive_error(card_id, force?)
    end
    |> tap_ok(fn _card -> log_event(card_id, "archived", %{}) end)
  end

  defp archive_error(card_id, force?) do
    case Repo.get(BoardCard, card_id) do
      nil -> {:error, :not_found}
      %{status: "archived"} -> {:error, :already_archived}
      %{status: "running"} when not force? -> {:error, :running}
      _ -> {:error, :conflict}
    end
  end

  @doc "`archived → todo`."
  @spec unarchive(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def unarchive(card_id) do
    transition(card_id, "archived", status: "todo")
    |> tap_ok(fn _card -> log_event(card_id, "unarchived", %{}) end)
  end

  @doc "Append a comment to a card's audit trail. Doesn't touch its status; a pure note."
  @spec comment(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def comment(card_id, author, text) do
    if Config.get_board_card(card_id) do
      log_event(card_id, "comment", %{"by" => author, "text" => text})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  `todo → ready` if every dependency is `done` (never `archived`). Called by the scheduler
  tick for every `todo` card; an unmet-dependency `{:error, _}` is the normal, expected
  outcome on most ticks, not something to log.
  """
  @spec promote_if_ready(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def promote_if_ready(card_id) do
    Repo.transaction(fn ->
      case Repo.get(BoardCard, card_id) do
        nil ->
          Repo.rollback(:not_found)

        %{status: "todo"} = card ->
          if deps_done?(card.depends_on) do
            card |> BoardCard.changeset(%{status: "ready", updated_at: now()}) |> Repo.update!()
          else
            Repo.rollback(:deps_not_done)
          end

        _card ->
          Repo.rollback(:not_todo)
      end
    end)
  end

  defp deps_done?([]), do: true

  defp deps_done?(dep_ids) do
    statuses = from(c in BoardCard, where: c.id in ^dep_ids, select: {c.id, c.status}) |> Repo.all() |> Map.new()
    Enum.all?(dep_ids, &(statuses[&1] == "done"))
  end

  @doc """
  If `card_id` is `running` and its claim has outlived `timeout_s`, block it (a stalled
  claim). `timeout_s` of `0`/`nil` means the board never auto-blocks on timeout.
  """
  @spec reclaim_if_timed_out(String.t(), integer() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def reclaim_if_timed_out(_card_id, timeout_s) when timeout_s in [0, nil], do: {:error, :no_timeout}

  def reclaim_if_timed_out(card_id, timeout_s) do
    cutoff = now() - timeout_s
    query = from(c in BoardCard, where: c.id == ^card_id and c.status == "running" and c.claimed_at < ^cutoff)

    case update_and_get(query, [status: "blocked", block_reason: "claim timed out"], card_id) do
      {:ok, card} -> {:ok, card}
      :miss -> reclaim_error(card_id)
    end
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => "claim timed out"}) end)
  end

  defp reclaim_error(card_id) do
    case Repo.get(BoardCard, card_id) do
      nil -> {:error, :not_found}
      %{status: "running", claimed_at: c} when is_integer(c) -> {:error, :not_timed_out}
      _ -> {:error, :not_applicable}
    end
  end

  @doc """
  `ready` cards on `board_id` with an assignee and no current claim, ordered highest-priority
  (then oldest) first: what the scheduler auto-dispatches, and what a manual "claim next"
  action would offer.
  """
  @spec due_for_dispatch(String.t()) :: [BoardCard.t()]
  def due_for_dispatch(board_id) do
    board_id
    |> Config.board_cards_for()
    |> Enum.filter(&(&1.status == "ready" and &1.assignee not in [nil, ""] and is_nil(&1.claimed_by)))
    |> Enum.sort_by(&{-&1.priority, &1.created_at})
  end

  @doc """
  Does `card` auto-fire on its own on `board`'s tick? The card's own `auto_dispatch`
  wins when set (`true`/`false`); `nil` (the default) inherits the board's setting. A
  manual `claim` always works regardless of this; it only gates the scheduler's tick.
  """
  @spec effective_auto_dispatch?(Board.t(), BoardCard.t()) :: boolean()
  def effective_auto_dispatch?(%Board{auto_dispatch: board_default}, %BoardCard{auto_dispatch: nil}), do: board_default
  def effective_auto_dispatch?(%Board{}, %BoardCard{auto_dispatch: override}), do: override

  ###
  ### internal
  ###

  # A generic `status_from → patch` transition, the shape every simple state change shares
  # (claim/complete/block/unblock/force_ready/unarchive). One conditional UPDATE, gated on
  # both id and the precondition status - the returned row count is the atomic result.
  # `archive/2` and `promote_if_ready/1` have their own precondition logic and don't fit
  # this shape.
  defp transition(card_id, from_status, patch) do
    query = from(c in BoardCard, where: c.id == ^card_id and c.status == ^from_status)

    case update_and_get(query, patch, card_id) do
      {:ok, card} -> {:ok, card}
      :miss -> transition_error(card_id, from_status)
    end
  end

  defp transition_error(card_id, _from_status) do
    case Repo.get(BoardCard, card_id) do
      nil -> {:error, :not_found}
      %{status: actual} -> {:error, {:unexpected_status, actual}}
    end
  end

  # set_auto_dispatch/2's shape: no precondition, so a plain unconditional update - still
  # goes through the same {count, _} check to report :not_found instead of silently
  # succeeding at nothing on an id that doesn't exist.
  defp update_unconditionally(card_id, patch) do
    query = from(c in BoardCard, where: c.id == ^card_id)

    case update_and_get(query, patch, card_id) do
      {:ok, card} -> {:ok, card}
      :miss -> {:error, :not_found}
    end
  end

  # The conditional UPDATE's returned row count is already the atomic "did this precondition
  # hold" signal - but a separate, later `Repo.get` to hand the caller the fresh row is not
  # atomic with it: `pool_size: 1` only serializes calls made *inside* the same transaction
  # (see the moduledoc), so two consecutive top-level calls from this process can still be
  # interleaved by a concurrent delete (e.g. the card's board being force-deleted) landing
  # between the write and the read. Wrapping both in one transaction closes that gap instead
  # of handing a caller a `{:ok, nil}` for a row that no longer exists.
  defp update_and_get(query, patch, card_id) do
    patch = Keyword.put(patch, :updated_at, now())

    Repo.transaction(fn ->
      case Repo.update_all(query, set: patch) do
        {1, _} -> Repo.get(BoardCard, card_id)
        {0, _} -> nil
      end
    end)
    |> case do
      {:ok, nil} -> :miss
      {:ok, card} -> {:ok, card}
    end
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  # Every dependency must exist, belong to the same board (cross-board deps are rejected
  # outright), and adding this edge must not create a cycle: checked by asking whether the
  # graph already reaches back to `card_id` starting from any proposed dependency.
  defp valid_deps?(board_id, card_id, depends_on) do
    cards = from(c in BoardCard, where: c.board == ^board_id) |> Repo.all() |> Map.new(&{&1.id, &1})

    Enum.all?(depends_on, &match?(%BoardCard{board: ^board_id}, cards[&1])) and
      not Enum.any?(depends_on, &reaches?(cards, &1, card_id, []))
  end

  defp reaches?(_cards, current, target, _seen) when current == target, do: true

  defp reaches?(cards, current, target, seen) do
    if current in seen do
      false
    else
      seen = [current | seen]
      deps = if cards[current], do: cards[current].depends_on, else: []
      Enum.any?(deps, &reaches?(cards, &1, target, seen))
    end
  end

  defp log_event(card_id, event, extra) do
    Pepe.Board.Log.append(card_id, event, extra)
    Phoenix.PubSub.broadcast(Pepe.PubSub, events_topic(), {:board_event, card_id, event})
  rescue
    _ -> :ok
  end

  defp new_card_id, do: "c_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  defp now, do: System.system_time(:second)

  # `||` would treat an explicit `false` the same as "not provided": wrong for a real
  # boolean field like `auto_dispatch`, where `false` is a meaningful value, not a gap.
  # Map.fetch/2 (present vs. absent) is what actually distinguishes the two.
  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, v} -> v
      :error -> Map.get(attrs, to_string(key))
    end
  end
end
