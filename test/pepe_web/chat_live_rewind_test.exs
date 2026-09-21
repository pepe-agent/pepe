defmodule PepeWeb.ChatLiveRewindTest do
  @moduledoc """
  `/undo`, `/rewind` and `/retry` typed into the dashboard chat, against a session whose
  earlier turn really wrote a file. The result of each is a message at the top of the page,
  so that is what is read, along with what is left on disk.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chat_rewind_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.WriterLLM, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "assistant", model: "mock", tools: ["write_file"], auto_approve: ["*"], max_iterations: 3})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    key = "web:rewind-#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "assistant")

    workspace = Workspace.dir("assistant")
    File.mkdir_p!(workspace)
    notes = Path.join(workspace, "notes.md")
    File.write!(notes, "original")

    {:ok, _} = Session.chat(key, "WRITE notes.md v2", learn: false, authorize: fn _n, _a, _c -> :once end)

    {:ok, key: key, notes: notes}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp send_text(view, text) do
    view |> form("form[phx-submit=send]", %{"text" => text}) |> render_submit()
  end

  test "a bare /rewind lists the turns with what each changed", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/rewind")

    assert html =~ "Recent turns, newest first:"
    assert html =~ "1. WRITE notes.md v2 (1 file)"
    assert html =~ "/rewind N files"
  end

  test "/rewind 1 puts the file back and drops the turn", %{key: key, notes: notes} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/rewind 1")

    assert html =~ "Rewound 1 turn."
    assert html =~ "Put back 1 file: notes.md."
    # The conversation is checked in the session: the sidebar still titles it by its first message.
    assert Session.status(key).turns == 0
    assert File.read!(notes) == "original"
  end

  test "/rewind 1 files puts the file back and keeps the conversation", %{key: key, notes: notes} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/rewind 1 files")

    assert html =~ "The conversation is unchanged."
    assert Session.status(key).turns == 1
    assert File.read!(notes) == "original"
  end

  test "/rewind 1 chat leaves the file and says so", %{key: key, notes: notes} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/rewind 1 chat")

    assert html =~ "The 1 file those turns changed was left as it is."
    assert File.read!(notes) == "v2"
  end

  test "/undo takes back the conversation and leaves the file", %{key: key, notes: notes} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/undo")

    assert html =~ "left as it is"
    assert Session.status(key).turns == 0
    assert File.read!(notes) == "v2"
  end

  test "a /rewind it cannot read explains itself and changes nothing", %{key: key, notes: notes} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/rewind banana")

    assert html =~ "Usage: /rewind N"
    assert Session.status(key).turns == 1
    assert File.read!(notes) == "v2"
  end

  test "/retry files puts the file back before the same message goes out again", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/retry files")

    assert html =~ "Put back 1 file: notes.md."
  end

  test "/retry with nothing to retry says so", %{key: key} do
    Session.reset(key)
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    assert send_text(view, "/retry") =~ "Nothing to retry yet."
  end
end
