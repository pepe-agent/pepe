defmodule Pepe.Board.SchedulerTest do
  @moduledoc """
  The tick-driven parts of the board: promotion, timeout reclaim, and - the one genuinely
  concurrent path - auto-dispatch plus the auto-block that closes "the agent finished its
  turn without ever calling `complete`/`block`" (see `Pepe.Board.Scheduler`'s moduledoc).
  Mirrors `test/pepe/cron/scheduler_test.exs`'s pattern: `send(Scheduler, :tick)` to fire a
  tick on demand instead of waiting out the real 30s interval.
  """
  use ExUnit.Case, async: false

  alias Pepe.Board
  alias Pepe.Board.Scheduler
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_bsch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    start_supervised!({Task.Supervisor, name: Pepe.Board.TaskSupervisor})
    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # A model that answers plainly and never calls a tool - the dispatched turn finishes
  # normally without ever calling `board complete`/`block`, the exact "protocol violation"
  # case the scheduler's `:DOWN` handler exists for.
  defp silent_worker! do
    {:ok, server} =
      Bandit.start_link(
        plug: fn conn, _ ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s({"choices":[{"index":0,"message":{"role":"assistant","content":"looked into it"},"finish_reason":"stop"}]})
          )
        end,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "silent", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
    Config.put_agent(%Agent{name: "worker", model: "silent", system_prompt: "hi", tools: []})
    :ok
  end

  test "auto_dispatch claims a ready card and dispatches it to the assignee" do
    silent_worker!()
    {:ok, board} = Board.create_board(%{project: nil, name: "auto-#{System.unique_integer([:positive])}", auto_dispatch: true})
    {:ok, card} = Board.create_card(%{board: board.id, title: "look into it", body: "check the logs", assignee: "worker"})
    Board.force_ready(card.id)

    Phoenix.PubSub.subscribe(Pepe.PubSub, Board.events_topic())
    send(Scheduler, :tick)

    assert_receive {:board_event, id, "claimed"}, 2_000
    assert id == card.id
    assert Config.get_board_card(card.id).status == "running"
  end

  test "a reply that never calls complete/block leaves the card blocked, not silently re-dispatched" do
    silent_worker!()
    {:ok, board} = Board.create_board(%{project: nil, name: "auto2-#{System.unique_integer([:positive])}", auto_dispatch: true})
    {:ok, card} = Board.create_card(%{board: board.id, title: "look into it", body: "check the logs", assignee: "worker"})
    Board.force_ready(card.id)

    Phoenix.PubSub.subscribe(Pepe.PubSub, Board.events_topic())
    send(Scheduler, :tick)

    assert_receive {:board_event, _id, "claimed"}, 2_000
    assert_receive {:board_event, _id, "blocked"}, 2_000

    updated = Config.get_board_card(card.id)
    assert updated.status == "blocked"
    assert updated.block_reason == "worker exited without completing"
  end

  test "auto_dispatch: false never fires a ready card on its own" do
    {:ok, board} = Board.create_board(%{project: nil, name: "manual-#{System.unique_integer([:positive])}", auto_dispatch: false})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x", assignee: "worker"})
    Board.force_ready(card.id)

    Phoenix.PubSub.subscribe(Pepe.PubSub, Board.events_topic())
    send(Scheduler, :tick)

    refute_receive {:board_event, _id, "claimed"}, 300
    assert Config.get_board_card(card.id).status == "ready"
  end

  test "a card's own auto_dispatch override wins over its board's setting, either direction" do
    silent_worker!()

    # Manual board, one card overridden to fire on its own.
    {:ok, board} = Board.create_board(%{project: nil, name: "override1-#{System.unique_integer([:positive])}", auto_dispatch: false})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x", assignee: "worker", auto_dispatch: true})
    Board.force_ready(card.id)

    Phoenix.PubSub.subscribe(Pepe.PubSub, Board.events_topic())
    send(Scheduler, :tick)
    card_id = card.id
    assert_receive {:board_event, ^card_id, "claimed"}, 2_000

    # Auto board, one card overridden to stay manual.
    {:ok, board2} = Board.create_board(%{project: nil, name: "override2-#{System.unique_integer([:positive])}", auto_dispatch: true})
    {:ok, card2} = Board.create_card(%{board: board2.id, title: "x", assignee: "worker", auto_dispatch: false})
    Board.force_ready(card2.id)

    send(Scheduler, :tick)
    refute_receive {:board_event, _id2, "claimed"}, 300
    assert Config.get_board_card(card2.id).status == "ready"
  end

  test "a tick promotes todo -> ready once every dependency is done" do
    {:ok, board} = Board.create_board(%{project: nil, name: "promo-#{System.unique_integer([:positive])}"})
    {:ok, dep} = Board.create_card(%{board: board.id, title: "dep"})
    {:ok, card} = Board.create_card(%{board: board.id, title: "waits on dep", depends_on: [dep.id]})
    Board.force_ready(dep.id)
    Board.claim(dep.id, "x")
    Board.complete(dep.id)

    assert Config.get_board_card(card.id).status == "todo"
    send(Scheduler, :tick)
    Process.sleep(50)

    assert Config.get_board_card(card.id).status == "ready"
  end

  test "a tick blocks a running card whose claim has outlived the board's claim_timeout_s" do
    {:ok, board} = Board.create_board(%{project: nil, name: "timeout-#{System.unique_integer([:positive])}", claim_timeout_s: 10})
    {:ok, card} = Board.create_card(%{board: board.id, title: "x", assignee: "worker"})
    Board.force_ready(card.id)
    Board.claim(card.id, "somewhere")

    stale = %{Config.get_board_card(card.id) | claimed_at: System.system_time(:second) - 100}
    Config.put_board_card(stale)

    send(Scheduler, :tick)
    Process.sleep(50)

    updated = Config.get_board_card(card.id)
    assert updated.status == "blocked"
    assert updated.block_reason == "claim timed out"
  end
end
