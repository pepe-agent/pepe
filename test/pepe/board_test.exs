defmodule Pepe.BoardTest do
  @moduledoc """
  `Pepe.Board`'s state machine and its compare-and-swap claim mechanism (see
  `Pepe.Config.Writer.update_cas/1`) - headless, no session/model involved. The scheduler's
  own dispatch/timeout/crash behavior is covered separately in `board/scheduler_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Board
  alias Pepe.Config

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_board_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp new_board(attrs \\ %{}) do
    {:ok, board} = Board.create_board(Map.merge(%{project: nil, name: "eng-#{System.unique_integer([:positive])}"}, attrs))
    board
  end

  defp new_card(board, attrs \\ %{}) do
    {:ok, card} = Board.create_card(Map.merge(%{board: board.id, title: "a card", body: "do the thing", assignee: "worker"}, attrs))
    card
  end

  describe "create_board/1" do
    test "creates a board scoped to the given project" do
      {:ok, board} = Board.create_board(%{project: "acme", name: "backlog"})

      assert board.id == "acme/backlog"
      assert board.project == "acme"
      assert board.auto_dispatch == false
      assert board.claim_timeout_s == 1800
    end

    test "refuses a name collision within the same project" do
      Board.create_board(%{project: "acme", name: "backlog"})
      assert Board.create_board(%{project: "acme", name: "backlog"}) == {:error, :already_exists}
    end

    test "the same name in different projects is not a collision" do
      assert {:ok, _} = Board.create_board(%{project: "acme", name: "backlog"})
      assert {:ok, _} = Board.create_board(%{project: "globex", name: "backlog"})
    end
  end

  describe "delete_board/2" do
    test "refuses to delete a board with cards" do
      board = new_board()
      new_card(board)

      assert Board.delete_board(board.id) == {:error, {:not_empty, 1}}
      assert Config.get_board(board.id)
    end

    test "force: true cascades, dropping the board's cards too" do
      board = new_board()
      card = new_card(board)

      assert Board.delete_board(board.id, force: true) == :ok
      refute Config.get_board(board.id)
      refute Config.get_board_card(card.id)
    end
  end

  describe "create_card/1" do
    test "fails on an unknown board" do
      assert Board.create_card(%{board: "no-such-board", title: "x"}) == {:error, :board_not_found}
    end

    test "rejects a dependency on a card from a different board" do
      board = new_board()
      other_board = new_board()
      foreign = new_card(other_board)

      assert Board.create_card(%{board: board.id, title: "x", depends_on: [foreign.id]}) == {:error, :invalid_dependency}
    end

    test "rejects an unknown dependency id" do
      board = new_board()
      assert Board.create_card(%{board: board.id, title: "x", depends_on: ["ghost"]}) == {:error, :invalid_dependency}
    end
  end

  describe "link/2 and cycle detection" do
    test "adds a same-board dependency" do
      board = new_board()
      a = new_card(board)
      b = new_card(board)

      {:ok, updated} = Board.link(b.id, a.id)
      assert updated.depends_on == [a.id]
    end

    test "rejects a direct self-dependency" do
      board = new_board()
      a = new_card(board)

      assert Board.link(a.id, a.id) == {:error, :invalid_dependency}
    end

    test "rejects a dependency that would close a cycle" do
      board = new_board()
      a = new_card(board)
      b = new_card(board)
      {:ok, _} = Board.link(b.id, a.id)

      # a -> b would close a cycle: a depends_on b, b depends_on a.
      assert Board.link(a.id, b.id) == {:error, :invalid_dependency}
    end
  end

  describe "claim/2" do
    test "moves a ready card to running and records the claimant" do
      board = new_board()
      card = new_card(board)
      {:ok, ready} = Board.force_ready(card.id)
      assert ready.status == "ready"

      {:ok, claimed} = Board.claim(card.id, "worker-session")
      assert claimed.status == "running"
      assert claimed.claimed_by == "worker-session"
      assert claimed.claimed_at
    end

    test "refuses a card that isn't ready" do
      board = new_board()
      card = new_card(board)
      assert card.status == "todo"

      assert Board.claim(card.id, "x") == {:error, {:unexpected_status, "todo"}}
    end

    test "exactly one of many concurrent claims on the same card wins" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)

      results =
        1..20
        |> Enum.map(fn i -> Task.async(fn -> Board.claim(card.id, "claimant-#{i}") end) end)
        |> Task.await_many(10_000)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      assert oks == 1
      assert Config.get_board_card(card.id).status == "running"
    end
  end

  describe "block_if_still_running/3" do
    test "blocks a card still running under the claim the caller captured" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      {:ok, claimed} = Board.claim(card.id, "worker-a")

      {:ok, blocked} = Board.block_if_still_running(card.id, claimed.claimed_by, claimed.claimed_at)
      assert blocked.status == "blocked"
      assert blocked.block_reason == "worker exited without completing"
    end

    test "is a no-op against a stale claim (ABA: reclaimed by someone else since)" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      {:ok, claimed_a} = Board.claim(card.id, "worker-a")

      # worker-a's dispatch died; before its :DOWN is handled, the card gets unstuck and
      # reclaimed by a completely different, still-legitimate run - the claimant differs
      # even if claimed_at (second-granularity) happens to coincide.
      Board.block(card.id, "reclaimed manually")
      Board.unblock(card.id)
      {:ok, claimed_b} = Board.claim(card.id, "worker-b")
      assert claimed_b.claimed_by != claimed_a.claimed_by

      assert Board.block_if_still_running(card.id, claimed_a.claimed_by, claimed_a.claimed_at) == {:error, :stale_claim}
      still_running = Config.get_board_card(card.id)
      assert still_running.status == "running"
      assert still_running.claimed_by == "worker-b"
    end
  end

  describe "heartbeat/2" do
    test "resets a stale claim's clock, so a still-active claim survives reclaim_if_timed_out" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      {:ok, claimed} = Board.claim(card.id, "worker-a")

      # Same simulated-staleness technique reclaim_if_timed_out/2's own tests use.
      stale = %{claimed | claimed_at: System.system_time(:second) - 100}
      Config.put_board_card(stale)

      {:ok, alive} = Board.heartbeat(card.id, "worker-a")
      assert alive.status == "running"
      # claimed_at itself is untouched - it's the claim's identity token
      # (block_if_still_running/3's ABA guard keys off it); only the separate
      # heartbeated_at liveness column moves.
      assert alive.claimed_at == stale.claimed_at
      assert alive.heartbeated_at > stale.claimed_at

      # The bug this closes: before the heartbeat, this exact staleness would have been
      # force-blocked as stalled (see reclaim_if_timed_out/2's own tests above) even
      # though the claim was genuinely still alive.
      assert Board.reclaim_if_timed_out(card.id, 10) == {:error, :not_timed_out}
    end

    test "is a no-op against a stale claim (ABA: reclaimed by someone else since)" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      {:ok, _claimed_a} = Board.claim(card.id, "worker-a")

      Board.block(card.id, "reclaimed manually")
      Board.unblock(card.id)
      {:ok, _claimed_b} = Board.claim(card.id, "worker-b")

      assert Board.heartbeat(card.id, "worker-a") == {:error, :not_your_claim}
      still_running = Config.get_board_card(card.id)
      assert still_running.claimed_by == "worker-b"
    end

    test "refuses a card that isn't running at all" do
      board = new_board()
      card = new_card(board)

      assert Board.heartbeat(card.id, "worker-a") == {:error, {:unexpected_status, "todo"}}
    end

    test "refuses an unknown card" do
      assert Board.heartbeat("nope", "worker-a") == {:error, :not_found}
    end

    test "a heartbeat during the run doesn't invalidate the scheduler's own dispatch-time claim token" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      {:ok, claimed} = Board.claim(card.id, "worker-a")

      # The scheduler captures {id, claimed_by, claimed_at} at dispatch time and holds onto
      # it to guard against the worker dying without calling complete/block - see
      # block_if_still_running/3's own moduledoc. A heartbeat happening mid-run must not
      # change what that captured token means.
      {:ok, _alive} = Board.heartbeat(card.id, "worker-a")

      assert {:ok, blocked} = Board.block_if_still_running(card.id, "worker-a", claimed.claimed_at)
      assert blocked.status == "blocked"
    end
  end

  describe "the rest of the state machine" do
    test "complete: running -> done" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      {:ok, done} = Board.complete(card.id, "all good")
      assert done.status == "done"
    end

    test "block: running -> blocked, with a reason" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      {:ok, blocked} = Board.block(card.id, "waiting on input")
      assert blocked.status == "blocked"
      assert blocked.block_reason == "waiting on input"
    end

    test "unblock: blocked -> ready, clearing the claim" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")
      Board.block(card.id, "stuck")

      {:ok, unblocked} = Board.unblock(card.id)
      assert unblocked.status == "ready"
      assert unblocked.claimed_by == nil
      assert unblocked.block_reason == nil
    end

    test "archive refuses a running card without force, force: true overrides" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      assert Board.archive(card.id) == {:error, :running}
      {:ok, archived} = Board.archive(card.id, force: true)
      assert archived.status == "archived"
    end

    test "unarchive: archived -> todo" do
      board = new_board()
      card = new_card(board)
      Board.archive(card.id, force: true)

      {:ok, back} = Board.unarchive(card.id)
      assert back.status == "todo"
    end
  end

  describe "promote_if_ready/1" do
    test "promotes todo -> ready once every dependency is done" do
      board = new_board()
      dep = new_card(board)
      card = new_card(board, %{depends_on: [dep.id]})

      assert Board.promote_if_ready(card.id) == {:error, :deps_not_done}

      Board.force_ready(dep.id)
      Board.claim(dep.id, "x")
      Board.complete(dep.id)

      {:ok, promoted} = Board.promote_if_ready(card.id)
      assert promoted.status == "ready"
    end

    test "an archived dependency never satisfies the gate" do
      board = new_board()
      dep = new_card(board)
      card = new_card(board, %{depends_on: [dep.id]})
      Board.archive(dep.id, force: true)

      assert Board.promote_if_ready(card.id) == {:error, :deps_not_done}
    end
  end

  describe "reclaim_if_timed_out/2" do
    test "blocks a running card whose claim has outlived the timeout" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      # Simulate an old claim by writing claimed_at directly into the past.
      stale = %{Config.get_board_card(card.id) | claimed_at: System.system_time(:second) - 100}
      Config.put_board_card(stale)

      {:ok, blocked} = Board.reclaim_if_timed_out(card.id, 10)
      assert blocked.status == "blocked"
      assert blocked.block_reason == "claim timed out"
    end

    test "does nothing while still within the timeout" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      assert Board.reclaim_if_timed_out(card.id, 1800) == {:error, :not_timed_out}
    end

    test "0/nil timeout never auto-blocks" do
      board = new_board()
      card = new_card(board)
      Board.force_ready(card.id)
      Board.claim(card.id, "x")

      assert Board.reclaim_if_timed_out(card.id, 0) == {:error, :no_timeout}
      assert Board.reclaim_if_timed_out(card.id, nil) == {:error, :no_timeout}
    end
  end

  describe "due_for_dispatch/1" do
    test "only ready, assigned, unclaimed cards - highest priority (then oldest) first" do
      board = new_board()
      low = new_card(board, %{title: "low", priority: 1})
      high = new_card(board, %{title: "high", priority: 5})
      unassigned = new_card(board, %{title: "unassigned", assignee: nil})
      Enum.each([low, high, unassigned], &Board.force_ready(&1.id))

      assert Board.due_for_dispatch(board.id) |> Enum.map(& &1.id) == [high.id, low.id]
    end
  end

  describe "effective_auto_dispatch?/2 (per-card override)" do
    test "nil (the default) inherits the board's own setting" do
      auto = %Pepe.Config.Board{auto_dispatch: true}
      manual = %Pepe.Config.Board{auto_dispatch: false}
      card = %Pepe.Config.BoardCard{auto_dispatch: nil}

      assert Board.effective_auto_dispatch?(auto, card)
      refute Board.effective_auto_dispatch?(manual, card)
    end

    test "a card override wins regardless of the board's own setting" do
      auto = %Pepe.Config.Board{auto_dispatch: true}
      manual = %Pepe.Config.Board{auto_dispatch: false}

      refute Board.effective_auto_dispatch?(auto, %Pepe.Config.BoardCard{auto_dispatch: false})
      assert Board.effective_auto_dispatch?(manual, %Pepe.Config.BoardCard{auto_dispatch: true})
    end

    test "set_auto_dispatch/2 sets and clears the override, without touching status" do
      board = new_board()
      card = new_card(board)

      {:ok, updated} = Board.set_auto_dispatch(card.id, true)
      assert updated.auto_dispatch == true
      assert updated.status == "todo"

      {:ok, cleared} = Board.set_auto_dispatch(card.id, nil)
      assert cleared.auto_dispatch == nil
    end
  end
end
