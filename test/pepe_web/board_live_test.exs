defmodule PepeWeb.BoardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Board
  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_boardui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "worker"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp create_board(view, params) do
    render_click(view, "board_new")
    render_submit(view, "board_create", %{"board" => params})
  end

  defp create_card(view, params) do
    render_click(view, "card_new")
    render_submit(view, "card_create", %{"card" => params})
  end

  test "an empty page invites the operator to create the first board" do
    {:ok, _view, html} = live(conn(), "/board")
    assert html =~ "No boards yet."
  end

  test "creating a board jumps straight into it, and it's listed with auto_dispatch shown when on" do
    {:ok, view, _html} = live(conn(), "/board")

    html = create_board(view, %{"name" => "Engineering", "auto_dispatch" => "true", "claim_timeout_s" => "600"})

    assert html =~ "Board created."
    assert html =~ "Engineering"
    assert [board] = Config.boards()
    assert board.name == "Engineering"
    assert board.auto_dispatch
    assert board.claim_timeout_s == 600

    html = render_click(view, "board_back")
    assert html =~ "auto-dispatch"
  end

  test "a board name collision is rejected" do
    {:ok, view, _html} = live(conn(), "/board")
    create_board(view, %{"name" => "Engineering"})

    html = create_board(view, %{"name" => "Engineering"})
    assert html =~ "already exists"
  end

  test "a board with no name is rejected" do
    {:ok, view, _html} = live(conn(), "/board")
    html = create_board(view, %{"name" => ""})

    assert html =~ "can&#39;t be blank"
    assert Config.boards() == []
  end

  test "selecting a board shows its cards grouped by status" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, todo} = Board.create_card(%{board: board.id, title: "a todo card"})
    {:ok, ready} = Board.create_card(%{board: board.id, title: "a ready card"})
    Board.force_ready(ready.id)

    {:ok, view, _html} = live(conn(), "/board")
    html = render_click(view, "board_select", %{"id" => board.id})

    assert html =~ "a todo card"
    assert html =~ "a ready card"
    assert html =~ todo.id
    assert html =~ ready.id
    assert html =~ "Claim"
  end

  test "creating a card on the selected board lands it in To do" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    html = create_card(view, %{"title" => "fix the thing", "assignee" => "worker", "priority" => "2"})

    assert html =~ "Card created."
    assert html =~ "fix the thing"
    assert [card] = Config.board_cards_for(board.id)
    assert card.title == "fix the thing"
    assert card.assignee == "worker"
    assert card.priority == 2
    assert card.status == "todo"
  end

  test "creating a card with an explicit auto-dispatch override persists it" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    create_card(view, %{"title" => "x", "auto_dispatch" => "false"})

    assert [card] = Config.board_cards_for(board.id)
    assert card.auto_dispatch == false
  end

  test "the per-card auto-dispatch select overrides the board's own setting" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng", auto_dispatch: true})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    render_change(view, "card_set_auto_dispatch", %{"id" => card.id, "value" => "off"})
    assert Config.get_board_card(card.id).auto_dispatch == false

    render_change(view, "card_set_auto_dispatch", %{"id" => card.id, "value" => "inherit"})
    assert Config.get_board_card(card.id).auto_dispatch == nil
  end

  test "claim moves a ready card to running, as \"dashboard\"" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    html = render_click(view, "card_claim", %{"id" => card.id})
    assert Config.get_board_card(card.id).status == "running"
    assert Config.get_board_card(card.id).claimed_by == "dashboard"
    assert html =~ "claimed by"
  end

  test "unblock moves a blocked card back to ready" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker")
    Board.block(card.id, "stuck")

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    render_click(view, "card_unblock", %{"id" => card.id})
    assert Config.get_board_card(card.id).status == "ready"
  end

  test "archive force-archives a running card, and it shows under Show archived" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker")

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    render_click(view, "card_archive", %{"id" => card.id})
    assert Config.get_board_card(card.id).status == "archived"

    html = render_click(view, "toggle_archived")
    assert html =~ "x</div>" or html =~ ">x<"
  end

  test "removing a non-empty board fails, an empty one succeeds" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, _card} = Board.create_card(%{board: board.id, title: "x"})

    {:ok, view, _html} = live(conn(), "/board")

    html = render_click(view, "board_remove", %{"id" => board.id})
    assert html =~ "Delete them first"
    assert Config.get_board(board.id)

    {:ok, empty} = Board.create_board(%{project: nil, name: "empty-one"})
    html = render_click(view, "board_remove", %{"id" => empty.id})
    refute html =~ empty.id
    refute Config.get_board(empty.id)
  end

  test "the view refreshes live when a card changes elsewhere (the tool, the scheduler)" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)

    {:ok, view, _html} = live(conn(), "/board")
    render_click(view, "board_select", %{"id" => board.id})

    Board.claim(card.id, "worker")
    html = render(view)

    assert html =~ "claimed by"
  end
end
