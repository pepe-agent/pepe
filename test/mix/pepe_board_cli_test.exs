defmodule Mix.Tasks.PepeBoardHeartbeatCliTest do
  @moduledoc """
  `mix pepe board card heartbeat ID [--as NAME]` - the CLI-side counterpart to the
  `board` agent tool's `heartbeat` action (see Pepe.Tools.BoardTest). No prior CLI
  test file covered `mix pepe board card ...` at all, so this is scoped to just the
  new subcommand, not a full backfill of the rest.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Board
  alias Pepe.Config

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_board_cli_#{System.unique_integer([:positive])}")
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

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "resets a stale claim's clock, defaulting the claimant to \"cli\"" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    {:ok, claimed} = Board.claim(card.id, "cli")
    stale_at = System.system_time(:second) - 100
    Config.put_board_card(%{claimed | claimed_at: stale_at})

    out = pepe(["board", "card", "heartbeat", card.id])

    assert out =~ "heartbeat recorded"
    assert Config.get_board_card(card.id).claimed_at > stale_at
  end

  test "--as names a specific claimant" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker-a")

    out = pepe(["board", "card", "heartbeat", card.id, "--as", "worker-a"])
    assert out =~ "heartbeat recorded"
  end

  test "a claim held by someone else is a clean error, not a crash" do
    {:ok, board} = Board.create_board(%{project: nil, name: "eng"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x"})
    Board.force_ready(card.id)
    Board.claim(card.id, "worker-a")

    err = pepe_err(["board", "card", "heartbeat", card.id, "--as", "worker-b"])
    assert err =~ "claimed by someone else"
  end

  test "mix pepe board help lists the heartbeat subcommand" do
    out = pepe(["board", "help"])
    assert out =~ "card heartbeat"
  end
end
