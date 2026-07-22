defmodule Pepe.Board.MigrationTest do
  @moduledoc """
  `Pepe.Board.Migration.run/0` - the one-time, operator-run import of boards and their
  cards from config.json's old "boards"/"board_cards" sections into `Pepe.Repo`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Board.Migration
  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_board_migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp write_legacy(boards, cards) do
    Config.update(fn config -> config |> Map.put("boards", boards) |> Map.put("board_cards", cards) end)
  end

  test "nothing to migrate when config.json never had boards/board_cards sections" do
    assert Migration.run() == %{imported: 0, already_present: 0, failed: []}
    assert Config.boards() == []
  end

  test "imports boards before cards, and removes both config.json keys" do
    write_legacy(
      %{"b_eng" => %{"project" => nil, "name" => "eng"}},
      %{"c1" => %{"board" => "b_eng", "title" => "fix the bug", "status" => "todo"}}
    )

    report = Migration.run()

    assert report == %{imported: 2, already_present: 0, failed: []}
    refute Config.load() |> Map.has_key?("boards")
    refute Config.load() |> Map.has_key?("board_cards")

    assert Config.get_board("b_eng").name == "eng"
    assert Config.get_board_card("c1").title == "fix the bug"
  end

  test "running it twice is a true no-op the second time" do
    write_legacy(%{"b_eng" => %{"project" => nil, "name" => "eng"}}, %{})

    assert Migration.run() == %{imported: 1, already_present: 0, failed: []}
    assert Migration.run() == %{imported: 0, already_present: 0, failed: []}
    assert length(Config.boards()) == 1
  end

  test "a malformed card is reported and neither config.json key is removed, even though the board imported fine" do
    write_legacy(
      %{"b_eng" => %{"project" => nil, "name" => "eng"}},
      %{"c_bad" => %{"board" => "b_eng", "title" => "x", "priority" => "not-a-number"}}
    )

    report = Migration.run()

    assert report.imported == 1
    assert [{"c_bad", _reason}] = report.failed
    assert Config.load() |> Map.has_key?("boards")
    assert Config.load() |> Map.has_key?("board_cards")
    # The board itself is not rolled back - it's a real row already, just the config.json
    # keys stay in place so a re-run sees the full picture instead of half of it.
    assert Config.get_board("b_eng").name == "eng"
  end

  test "an entry whose value isn't even a map is reported, not a crash" do
    write_legacy(%{"b_weird" => "not even a map"}, %{})

    report = Migration.run()

    assert [{"b_weird", _reason}] = report.failed
    assert Config.load() |> Map.has_key?("boards")
  end

  test "a card whose board doesn't exist fails as its own entry instead of crashing the run" do
    write_legacy(
      %{},
      %{"c_orphan" => %{"board" => "no_such_board", "title" => "x", "status" => "todo"}}
    )

    report = Migration.run()

    assert report.imported == 0
    assert [{"c_orphan", _reason}] = report.failed
    assert Config.load() |> Map.has_key?("board_cards")
  end
end
