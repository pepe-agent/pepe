defmodule Pepe.Tools.BoardTest do
  use ExUnit.Case, async: false

  alias Pepe.Board
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.Board, as: BoardTool

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_btool_#{System.unique_integer([:positive])}")
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

  defp ctx(name \\ "worker", session_key \\ nil), do: %{agent: %Agent{name: name}, session_key: session_key}

  test "refuses without a calling agent in context" do
    assert BoardTool.run(%{"action" => "list_boards"}, %{}) == {:error, "no calling agent in context"}
  end

  test "list_boards: empty, then shows a created one" do
    assert BoardTool.run(%{"action" => "list_boards"}, ctx()) == {:ok, "No boards yet."}

    BoardTool.run(%{"action" => "create_board", "name" => "eng"}, ctx())
    {:ok, out} = BoardTool.run(%{"action" => "list_boards"}, ctx())
    assert out =~ "eng"
  end

  test "create_board: refuses a name collision" do
    BoardTool.run(%{"action" => "create_board", "name" => "eng"}, ctx())
    assert {:error, msg} = BoardTool.run(%{"action" => "create_board", "name" => "eng"}, ctx())
    assert msg =~ "already exists"
  end

  test "create_card then show_card round-trips" do
    {:ok, "Created board " <> board_msg} = BoardTool.run(%{"action" => "create_board", "name" => "eng"}, ctx())
    board_id = String.trim_trailing(board_msg, ".")

    {:ok, "Created card " <> rest} =
      BoardTool.run(%{"action" => "create_card", "board_id" => board_id, "title" => "fix the thing", "assignee" => "worker"}, ctx())

    card_id = rest |> String.split(" ") |> List.first()

    {:ok, out} = BoardTool.run(%{"action" => "show_card", "card_id" => card_id}, ctx())
    assert out =~ "fix the thing"
    assert out =~ "status: todo"
    assert out =~ "assignee: worker"
  end

  test "create_card on an unknown board is a clean error" do
    assert {:error, msg} = BoardTool.run(%{"action" => "create_card", "board_id" => "ghost", "title" => "x"}, ctx())
    assert msg =~ "no such board"
  end

  test "list_cards filters by status" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, todo} = Board.create_card(%{board: board.id, title: "todo card"})
    {:ok, ready} = Board.create_card(%{board: board.id, title: "ready card"})
    Board.force_ready(ready.id)

    {:ok, out} = BoardTool.run(%{"action" => "list_cards", "board_id" => board.id, "status" => "ready"}, ctx())
    assert out =~ ready.id
    refute out =~ todo.id
  end

  test "link adds a dependency, rejects an invalid one" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, a} = Board.create_card(%{board: board.id, title: "a"})
    {:ok, b} = Board.create_card(%{board: board.id, title: "b"})

    {:ok, out} = BoardTool.run(%{"action" => "link", "card_id" => b.id, "depends_on_id" => a.id}, ctx())
    assert out =~ "now depends on"

    assert {:error, msg} = BoardTool.run(%{"action" => "link", "card_id" => a.id, "depends_on_id" => a.id}, ctx())
    assert msg =~ "cycle"
  end

  test "force_ready then claim moves a card through the pipeline" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})

    {:ok, _} = BoardTool.run(%{"action" => "force_ready", "card_id" => card.id}, ctx())
    {:ok, out} = BoardTool.run(%{"action" => "claim", "card_id" => card.id}, ctx("worker"))

    assert out =~ "running"
    assert Config.get_board_card(card.id).claimed_by == "worker"
  end

  describe "per-card auto_dispatch override" do
    test "create_card accepts an explicit false override, distinct from omitting it" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})

      {:ok, "Created card " <> rest} =
        BoardTool.run(%{"action" => "create_card", "board_id" => board.id, "title" => "x", "auto_dispatch" => false}, ctx())

      card_id = rest |> String.split(" ") |> List.first()
      assert Config.get_board_card(card_id).auto_dispatch == false
    end

    test "set_auto_dispatch overrides on/off, and inherit clears it back to nil" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})

      {:ok, out} = BoardTool.run(%{"action" => "set_auto_dispatch", "card_id" => card.id, "value" => "on"}, ctx())
      assert out =~ card.id
      assert Config.get_board_card(card.id).auto_dispatch == true

      BoardTool.run(%{"action" => "set_auto_dispatch", "card_id" => card.id, "value" => "off"}, ctx())
      assert Config.get_board_card(card.id).auto_dispatch == false

      BoardTool.run(%{"action" => "set_auto_dispatch", "card_id" => card.id, "value" => "inherit"}, ctx())
      assert Config.get_board_card(card.id).auto_dispatch == nil
    end

    test "set_auto_dispatch rejects a bad value" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})

      assert {:error, msg} = BoardTool.run(%{"action" => "set_auto_dispatch", "card_id" => card.id, "value" => "sometimes"}, ctx())
      assert msg =~ "on"
    end

    test "show_card reflects the override" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x", auto_dispatch: true})

      {:ok, out} = BoardTool.run(%{"action" => "show_card", "card_id" => card.id}, ctx())
      assert out =~ "overridden for this card"
    end
  end

  describe "complete/block/comment infer card_id from a dispatched session" do
    test "complete works with no card_id when the session key names the card" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x", assignee: "worker"})
      Board.force_ready(card.id)
      Board.claim(card.id, "worker")

      session_key = "board:#{board.id}:#{card.id}"
      {:ok, out} = BoardTool.run(%{"action" => "complete"}, ctx("worker", session_key))

      assert out =~ "done"
    end

    test "complete without a card_id and no dispatched session is a clean error" do
      assert {:error, msg} = BoardTool.run(%{"action" => "complete"}, ctx("worker", nil))
      assert msg =~ "card_id"
    end

    test "block requires text (the reason)" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
      Board.force_ready(card.id)
      Board.claim(card.id, "worker")

      assert {:error, msg} = BoardTool.run(%{"action" => "block", "card_id" => card.id}, ctx())
      assert msg =~ "text"

      {:ok, out} = BoardTool.run(%{"action" => "block", "card_id" => card.id, "text" => "needs input"}, ctx())
      assert out =~ "blocked"
      assert Config.get_board_card(card.id).block_reason == "needs input"
    end

    test "comment doesn't change status and shows up in show_card" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})

      {:ok, _} = BoardTool.run(%{"action" => "comment", "card_id" => card.id, "text" => "checking on this"}, ctx())
      assert Config.get_board_card(card.id).status == "todo"

      {:ok, out} = BoardTool.run(%{"action" => "show_card", "card_id" => card.id}, ctx())
      assert out =~ "checking on this"
    end

    test "heartbeat resets the stall clock without changing status" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
      Board.force_ready(card.id)
      {:ok, claimed} = Board.claim(card.id, "worker")
      stale_at = System.system_time(:second) - 100
      Config.put_board_card(%{claimed | claimed_at: stale_at})

      {:ok, out} = BoardTool.run(%{"action" => "heartbeat", "card_id" => card.id}, ctx())

      assert out =~ "heartbeat recorded"
      refreshed = Config.get_board_card(card.id)
      assert refreshed.status == "running"
      assert refreshed.claimed_at > stale_at
    end

    test "heartbeat infers card_id from a dispatched session, same as complete/block/comment" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x", assignee: "worker"})
      Board.force_ready(card.id)
      Board.claim(card.id, "worker")

      session_key = "board:#{board.id}:#{card.id}"
      {:ok, out} = BoardTool.run(%{"action" => "heartbeat"}, ctx("worker", session_key))
      assert out =~ "heartbeat recorded"
    end

    test "heartbeat from someone else's claim is a clean error" do
      {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
      {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
      Board.force_ready(card.id)
      Board.claim(card.id, "worker-a")

      assert {:error, msg} = BoardTool.run(%{"action" => "heartbeat", "card_id" => card.id}, ctx("worker-b"))
      assert msg =~ "claimed by someone else"
    end
  end

  test "unblock moves a blocked card back to ready" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker")
    Board.block(card.id, "stuck")

    {:ok, out} = BoardTool.run(%{"action" => "unblock", "card_id" => card.id}, ctx())
    assert out =~ "ready"
  end

  test "archive refuses a running card, with no way to force it from the tool" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker")

    assert {:error, msg} = BoardTool.run(%{"action" => "archive", "card_id" => card.id}, ctx())
    assert msg =~ "dashboard"
    assert Config.get_board_card(card.id).status == "running"
  end

  test "the spec documents the auto_approve requirement for a dispatched assignee" do
    doc = BoardTool.spec() |> get_in(["function", "description"])
    assert doc =~ "auto_approve"
  end
end
