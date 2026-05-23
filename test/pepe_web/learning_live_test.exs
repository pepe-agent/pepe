defmodule PepeWeb.LearningLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Agent.Reflect
  alias Pepe.Agent.Workspace
  alias Pepe.Approval
  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_learnui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp write_memory(agent, file, content) do
    dir = Workspace.dir(agent)
    File.mkdir_p!(dir)
    path = Path.join(dir, file)
    File.write!(path, content)
    path
  end

  # A staged `write_file` call, exactly as consolidation would leave it behind.
  defp stage_write(agent, path, content) do
    {:ok, id, _entry} =
      Approval.stage(agent, %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{
          "name" => "write_file",
          "arguments" => Jason.encode!(%{"path" => path, "content" => content})
        }
      })

    id
  end

  test "the timeline lists what the agent has saved to memory" do
    write_memory("assistant", "MEMORY.md", "The XML load runs at 06:00.")

    {:ok, _view, html} = live(conn(), "/learn")

    assert html =~ "MEMORY.md"
    assert html =~ "The XML load runs at 06:00."
  end

  test "switching agents shows that agent's memory, never the other's" do
    write_memory("assistant", "MEMORY.md", "assistant remembers the XML load")
    Config.put_agent(%Agent{name: "sales"})
    write_memory("sales", "MEMORY.md", "sales remembers the pricing table")

    {:ok, view, html} = live(conn(), "/learn")
    assert html =~ "assistant remembers the XML load"
    refute html =~ "sales remembers the pricing table"

    html = render_change(view, "pick_learn_agent", %{"agent" => "default/sales"})
    assert html =~ "sales remembers the pricing table"
    refute html =~ "assistant remembers the XML load"
  end

  test "opening a memory item shows its file and saving writes it back" do
    path = write_memory("assistant", "MEMORY.md", "The XML load runs at 06:00.")

    {:ok, view, _html} = live(conn(), "/learn")

    html = render_click(view, "learn_open", %{"kind" => "memory", "title" => "MEMORY.md"})
    assert html =~ "The XML load runs at 06:00."
    assert html =~ path

    html =
      view
      |> form("form[phx-submit=learn_save]", %{"content" => "The XML load runs at 07:00."})
      |> render_submit()

    assert html =~ "Saved MEMORY.md."
    assert File.read!(path) == "The XML load runs at 07:00."
    assert html =~ "The XML load runs at 07:00."
  end

  test "closing the editor discards the edit" do
    path = write_memory("assistant", "MEMORY.md", "original")

    {:ok, view, _html} = live(conn(), "/learn")

    render_click(view, "learn_open", %{"kind" => "memory", "title" => "MEMORY.md"})
    render_click(view, "learn_close")

    assert File.read!(path) == "original"
  end

  test "writes staged for review are listed with the tool and the agent" do
    stage_write("assistant", "MEMORY.md", "a fact the agent invented")

    {:ok, _view, html} = live(conn(), "/learn")

    assert html =~ "1 write(s) awaiting your review"
    assert html =~ "write_file"
    assert html =~ "assistant"
  end

  test "approving a staged write applies it and clears it from the queue" do
    id = stage_write("assistant", "MEMORY.md", "The XML load runs at 06:00.")
    target = Path.join(Workspace.dir("assistant"), "MEMORY.md")
    refute File.exists?(target)

    {:ok, view, _html} = live(conn(), "/learn")

    html = render_click(view, "approve_write", %{"id" => id})

    assert html =~ "Approved and applied."
    assert File.read!(target) == "The XML load runs at 06:00."
    assert Approval.list() == []
    refute html =~ "awaiting your review"
    # The write landed in memory, so the timeline picks it up right away.
    assert html =~ "The XML load runs at 06:00."
  end

  test "rejecting a staged write drops it WITHOUT writing anything" do
    id = stage_write("assistant", "MEMORY.md", "a fact the agent invented")
    target = Path.join(Workspace.dir("assistant"), "MEMORY.md")

    {:ok, view, _html} = live(conn(), "/learn")

    html = render_click(view, "reject_write", %{"id" => id})

    assert html =~ "Rejected, nothing was written."
    refute File.exists?(target)
    assert Approval.list() == []
    refute html =~ "awaiting your review"
  end

  test "approving a write someone else already handled says so" do
    id = stage_write("assistant", "MEMORY.md", "gone")
    Approval.reject(id)

    {:ok, view, _html} = live(conn(), "/learn")

    assert render_click(view, "approve_write", %{"id" => id}) =~ "That write is no longer pending."
    refute File.exists?(Path.join(Workspace.dir("assistant"), "MEMORY.md"))
  end

  test "nightly consolidation is toggled on and off from the header" do
    {:ok, view, html} = live(conn(), "/learn")
    assert html =~ "Nightly: off"

    html = render_click(view, "toggle_auto")
    assert html =~ "Nightly: on"
    assert Reflect.auto?("default/assistant")

    html = render_click(view, "toggle_auto")
    assert html =~ "Nightly: off"
    refute Reflect.auto?("default/assistant")
  end

  test "a finished consolidation reports its summary and refreshes the timeline" do
    {:ok, view, _html} = live(conn(), "/learn")

    send(view.pid, {:consolidated, "assistant", {:ok, "merged 2 duplicate notes", []}})
    assert render(view) =~ "Consolidated: merged 2 duplicate notes"

    send(view.pid, {:consolidated, "assistant", {:error, :no_model}})
    assert render(view) =~ "Consolidation could not run."
  end
end
