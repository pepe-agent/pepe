defmodule Pepe.Board do
  @moduledoc """
  Card lifecycle: creating, linking dependencies, claiming, and moving a card through its
  status pipeline (`triage → todo → ready → running → done | blocked → archived`).

  Every state-changing operation here goes through `Pepe.Config.update_cas/1` with its
  precondition read from the config `update_cas` hands it, not one fetched earlier: that is
  what makes a `claim` race-free against a concurrent claim with no extra lock (see
  `Pepe.Config.Writer.update_cas/1`). The one rule that must never be broken anywhere in this
  module: no `get_in(config, ...)` followed by a *separate* `Config.update.../1` call; read
  and write happen inside the same `update_cas` callback, always.

  `Pepe.Board.Scheduler` is the tick-driven caller of `promote_if_ready/1`,
  `reclaim_if_timed_out/2`, and dispatch; `Pepe.Tools.Board` and the dashboard are the other
  two callers, for the same functions. There is no separate "coordinator" process gating
  these, on purpose (see the scheduler's moduledoc for why).
  """

  alias Pepe.Config
  alias Pepe.Config.Board
  alias Pepe.Config.BoardCard

  @doc "PubSub topic carrying `{:board_event, card_id, event}` for every card change."
  def events_topic, do: "boards:events"

  @doc "Create a board. Fails if `project`/`name` already identify one."
  @spec create_board(map()) :: {:ok, Board.t()} | {:error, term()}
  def create_board(attrs) do
    project = fetch(attrs, :project)
    name = fetch(attrs, :name)
    id = Pepe.Project.handle(project, name)

    Config.update_cas(fn config ->
      if get_in(config, ["boards", id]) do
        {:error, :already_exists}
      else
        board_map = %{
          "project" => project,
          "name" => name,
          "auto_dispatch" => fetch(attrs, :auto_dispatch) || false,
          "claim_timeout_s" => fetch(attrs, :claim_timeout_s) || 1800
        }

        {:ok, update_in(config, ["boards"], &Map.put(&1 || %{}, id, board_map))}
      end
    end)
    |> extract(["boards", id], &Board.from_map/1)
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

    Config.update_cas(fn config ->
      cond do
        is_nil(get_in(config, ["boards", board_id])) ->
          {:error, :board_not_found}

        not valid_deps?(config, board_id, id, depends_on) ->
          {:error, :invalid_dependency}

        true ->
          ts = now()

          card_map = %{
            "board" => board_id,
            "title" => fetch(attrs, :title),
            "body" => fetch(attrs, :body),
            "assignee" => fetch(attrs, :assignee),
            "status" => fetch(attrs, :status) || "todo",
            "priority" => fetch(attrs, :priority) || 0,
            "depends_on" => depends_on,
            "auto_dispatch" => fetch(attrs, :auto_dispatch),
            "claimed_by" => nil,
            "claimed_at" => nil,
            "block_reason" => nil,
            "created_at" => ts,
            "updated_at" => ts
          }

          {:ok, update_in(config, ["board_cards"], &Map.put(&1 || %{}, id, card_map))}
      end
    end)
    |> extract(["board_cards", id], &BoardCard.from_map/1)
    |> tap_ok(fn _card -> log_event(id, "created", %{}) end)
  end

  @doc "Add a dependency edge to an existing card. Same validation as `create_card/1`."
  @spec link(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def link(card_id, depends_on_id) do
    cas_card(card_id, fn config, m ->
      new_deps = Enum.uniq([depends_on_id | m["depends_on"] || []])

      if valid_deps?(config, m["board"], card_id, new_deps) do
        {:ok, put_in(config, ["board_cards", card_id], Map.merge(m, %{"depends_on" => new_deps, "updated_at" => now()}))}
      else
        {:error, :invalid_dependency}
      end
    end)
    |> tap_ok(fn _card -> log_event(card_id, "linked", %{"depends_on" => depends_on_id}) end)
  end

  @doc """
  Override (`true`/`false`) or clear (`nil`) this card's own `auto_dispatch`, regardless
  of its board's setting; see `effective_auto_dispatch?/2`. Never touches its status.
  """
  @spec set_auto_dispatch(String.t(), boolean() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def set_auto_dispatch(card_id, value) when is_boolean(value) or is_nil(value) do
    cas_card(card_id, fn config, m ->
      {:ok, put_in(config, ["board_cards", card_id], Map.merge(m, %{"auto_dispatch" => value, "updated_at" => now()}))}
    end)
    |> tap_ok(fn _card -> log_event(card_id, "auto_dispatch_set", %{"value" => value}) end)
  end

  @doc "`ready → running`. Works whether or not the board has `auto_dispatch` on."
  @spec claim(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def claim(card_id, claimant) do
    transition(card_id, "ready", %{"status" => "running", "claimed_by" => claimant, "claimed_at" => now()})
    |> tap_ok(fn _card -> log_event(card_id, "claimed", %{"by" => claimant}) end)
  end

  @doc "`running → done`."
  @spec complete(String.t(), String.t() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def complete(card_id, result \\ nil) do
    transition(card_id, "running", %{"status" => "done"})
    |> tap_ok(fn _card -> log_event(card_id, "completed", %{"result" => result}) end)
  end

  @doc "`running → blocked`, with a reason."
  @spec block(String.t(), String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def block(card_id, reason) do
    transition(card_id, "running", %{"status" => "blocked", "block_reason" => reason})
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => reason}) end)
  end

  @doc "If still `running`, block it: the dispatch working on it ended without calling `complete`/`block`."
  @spec block_if_still_running(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def block_if_still_running(card_id) do
    reason = "worker exited without completing"

    transition(card_id, "running", %{"status" => "blocked", "block_reason" => reason})
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => reason}) end)
  end

  @doc "`blocked → ready`, clearing the claim."
  @spec unblock(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def unblock(card_id) do
    transition(card_id, "blocked", %{"status" => "ready", "claimed_by" => nil, "claimed_at" => nil, "block_reason" => nil})
    |> tap_ok(fn _card -> log_event(card_id, "unblocked", %{}) end)
  end

  @doc "`todo → ready`, bypassing the dependency gate."
  @spec force_ready(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def force_ready(card_id) do
    transition(card_id, "todo", %{"status" => "ready"})
    |> tap_ok(fn _card -> log_event(card_id, "forced_ready", %{}) end)
  end

  @doc """
  Archive a card. Refuses on a `running` card unless `force: true` (the dashboard/CLI path -
  deliberately not exposed through `Pepe.Tools.Board`, see its moduledoc).
  """
  @spec archive(String.t(), keyword()) :: {:ok, BoardCard.t()} | {:error, term()}
  def archive(card_id, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    cas_card(card_id, fn config, m ->
      cond do
        m["status"] == "archived" -> {:error, :already_archived}
        m["status"] == "running" and not force? -> {:error, :running}
        true -> {:ok, put_in(config, ["board_cards", card_id], Map.merge(m, %{"status" => "archived", "updated_at" => now()}))}
      end
    end)
    |> tap_ok(fn _card -> log_event(card_id, "archived", %{}) end)
  end

  @doc "`archived → todo`."
  @spec unarchive(String.t()) :: {:ok, BoardCard.t()} | {:error, term()}
  def unarchive(card_id) do
    transition(card_id, "archived", %{"status" => "todo"})
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
    cas_card(card_id, fn config, m ->
      cards = get_in(config, ["board_cards"]) || %{}
      deps = m["depends_on"] || []

      cond do
        m["status"] != "todo" -> {:error, :not_todo}
        not Enum.all?(deps, &(get_in(cards, [&1, "status"]) == "done")) -> {:error, :deps_not_done}
        true -> {:ok, put_in(config, ["board_cards", card_id], Map.merge(m, %{"status" => "ready", "updated_at" => now()}))}
      end
    end)
  end

  @doc """
  If `card_id` is `running` and its claim has outlived `timeout_s`, block it (a stalled
  claim). `timeout_s` of `0`/`nil` means the board never auto-blocks on timeout.
  """
  @spec reclaim_if_timed_out(String.t(), integer() | nil) :: {:ok, BoardCard.t()} | {:error, term()}
  def reclaim_if_timed_out(_card_id, timeout_s) when timeout_s in [0, nil], do: {:error, :no_timeout}

  def reclaim_if_timed_out(card_id, timeout_s) do
    cas_card(card_id, fn config, m ->
      case m do
        %{"status" => "running", "claimed_at" => claimed_at} when is_integer(claimed_at) ->
          if now() - claimed_at > timeout_s do
            {:ok,
             put_in(
               config,
               ["board_cards", card_id],
               Map.merge(m, %{"status" => "blocked", "block_reason" => "claim timed out", "updated_at" => now()})
             )}
          else
            {:error, :not_timed_out}
          end

        _ ->
          {:error, :not_applicable}
      end
    end)
    |> tap_ok(fn _card -> log_event(card_id, "blocked", %{"reason" => "claim timed out"}) end)
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
  # (claim/complete/block/unblock/force_ready/unarchive). `archive/2` and `promote_if_ready/1`
  # have their own precondition logic and don't fit this shape.
  defp transition(card_id, from_status, patch) do
    cas_card(card_id, fn config, m ->
      if m["status"] == from_status do
        {:ok, put_in(config, ["board_cards", card_id], Map.merge(m, Map.put(patch, "updated_at", now())))}
      else
        {:error, {:unexpected_status, m["status"]}}
      end
    end)
  end

  # Runs `fun.(config, card_map)` (which must return `{:ok, new_config} | {:error, reason}`,
  # the `Config.update_cas/1` contract) against the freshly loaded config, only if the card
  # exists, and turns a success back into `{:ok, %BoardCard{}}`.
  defp cas_card(card_id, fun) do
    Config.update_cas(fn config ->
      case get_in(config, ["board_cards", card_id]) do
        nil -> {:error, :not_found}
        card_map -> fun.(config, card_map)
      end
    end)
    |> extract(["board_cards", card_id], &BoardCard.from_map/1)
  end

  defp extract({:ok, new_config}, path, from_map) do
    [id | _] = Enum.reverse(path)
    {:ok, get_in(new_config, path) |> Map.put("id", id) |> from_map.()}
  end

  defp extract({:error, _} = err, _path, _from_map), do: err

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  # Every dependency must exist, belong to the same board (cross-board deps are rejected
  # outright), and adding this edge must not create a cycle: checked by asking whether the
  # graph already reaches back to `card_id` starting from any proposed dependency.
  defp valid_deps?(config, board_id, card_id, depends_on) do
    cards = get_in(config, ["board_cards"]) || %{}

    Enum.all?(depends_on, &match?(%{"board" => ^board_id}, cards[&1])) and
      not Enum.any?(depends_on, &reaches?(cards, &1, card_id, MapSet.new()))
  end

  defp reaches?(_cards, current, target, _seen) when current == target, do: true

  defp reaches?(cards, current, target, seen) do
    if MapSet.member?(seen, current) do
      false
    else
      seen = MapSet.put(seen, current)
      get_in(cards, [current, "depends_on"]) |> List.wrap() |> Enum.any?(&reaches?(cards, &1, target, seen))
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
