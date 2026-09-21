defmodule Pepe.Gateways.TUIRewindTest do
  @moduledoc """
  The console's `/rewind`, `/undo` and `/retry`, typed into the real REPL against a real
  session. The turns that change a file are run first through the session (a person would
  have typed them earlier); the REPL then gets the commands, and what it prints and what is
  left on disk are checked.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Gateways.TUI

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tui_rewind_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.WriterLLM, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "console", model: "mock", tools: ["write_file"], auto_approve: ["*"], max_iterations: 3})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    key = "tui:rewind:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "console")

    workspace = Workspace.dir("console")
    File.mkdir_p!(workspace)
    notes = Path.join(workspace, "notes.md")
    File.write!(notes, "original")

    {:ok, _} = Session.chat(key, "WRITE notes.md v2", learn: false, authorize: fn _n, _a, _c -> :once end)

    {:ok, key: key, notes: notes}
  end

  defp run(key, lines) do
    capture_io([input: Enum.join(lines, "\n") <> "\n"], fn -> TUI.start("console", key) end)
  end

  test "a bare /rewind lists the turns and how to pick", %{key: key} do
    out = run(key, ["/rewind"])

    assert out =~ "Recent turns, newest first:"
    assert out =~ "1. WRITE notes.md v2 (1 file)"
    assert out =~ "/rewind N chat"
    assert out =~ "/rewind N files"
  end

  test "/rewind 1 puts the file back with the conversation", %{key: key, notes: notes} do
    out = run(key, ["/rewind 1"])

    assert out =~ "Rewound 1 turn."
    assert out =~ "Put back 1 file: notes.md."
    assert File.read!(notes) == "original"
    assert Session.status(key).turns == 0
  end

  test "/rewind 1 files puts the file back and keeps the conversation", %{key: key, notes: notes} do
    out = run(key, ["/rewind 1 files"])

    assert out =~ "The conversation is unchanged."
    assert out =~ "Put back 1 file: notes.md."
    assert File.read!(notes) == "original"
    assert Session.status(key).turns == 1
  end

  test "/rewind 1 chat leaves the file and says so", %{key: key, notes: notes} do
    out = run(key, ["/rewind 1 chat"])

    assert out =~ "The 1 file those turns changed was left as it is."
    assert File.read!(notes) == "v2"
    assert Session.status(key).turns == 0
  end

  test "/undo is conversation only and mentions what it left", %{key: key, notes: notes} do
    out = run(key, ["/undo"])

    assert out =~ "Undid your last message."
    assert out =~ "left as it is"
    assert File.read!(notes) == "v2"
  end

  test "/rewind with something unreadable shows how to use it", %{key: key} do
    out = run(key, ["/rewind banana"])

    assert out =~ "Usage: /rewind N"
    assert out =~ "/rewind N files"
    assert Session.status(key).turns == 1
  end

  test "/retry asks the same message again, once", %{key: key} do
    run(key, ["/retry"])

    # The reply streams from the session's own task, outside what the capture sees, so check
    # the conversation: the same message, answered again, and only once.
    history = Session.history(key)
    assert Enum.count(history, &(&1["role"] == "user" and &1["content"] == "WRITE notes.md v2")) == 1
    assert Enum.any?(history, &(&1["content"] == "wrote it"))
    assert Session.status(key).turns == 1
  end

  test "/retry files puts the file back first and says so", %{key: key, notes: notes} do
    out = run(key, ["/retry files"])

    assert out =~ "Put back 1 file: notes.md."
    # The model then wrote it again.
    assert File.read!(notes) == "v2"
    assert Session.status(key).turns == 1
  end

  test "/retry with nothing said says there is nothing to retry", %{key: key} do
    Session.reset(key)
    assert run(key, ["/retry"]) =~ "Nothing to retry yet."
  end

  test "the help line lists the new commands", %{key: key} do
    out = run(key, ["/help"])

    assert out =~ "/rewind <n>"
    assert out =~ "/retry"
  end
end
