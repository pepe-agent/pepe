defmodule Pepe.Agent.SessionRewindFilesTest do
  @moduledoc """
  `/rewind` and `/retry` when the turns being taken back changed files: real turns through a
  real session, a model that writes a file when asked, and the checkpoint store recording it
  at the tool choke point. What a person needs from it: the files come back with the
  conversation (or without it, when they say so), what they changed by hand is never
  overwritten, and the report says exactly what happened to each file.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Model

  setup context do
    home = Path.join(System.tmp_dir!(), "pepe_rewind_files_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.WriterLLM, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})

    Config.put_agent(%Pepe.Config.Agent{
      name: "writer",
      model: "mock",
      system_prompt: "You write files.",
      tools: ["write_file"],
      max_iterations: 3,
      checkpoints: context[:checkpoints] != false
    })

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    key = "test:rewind_files:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "writer")

    workspace = Workspace.dir("writer")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "notes.md"), "original")
    {:ok, key: key, notes: Path.join(workspace, "notes.md"), workspace: workspace}
  end

  defp ask(key, text), do: {:ok, _} = Session.chat(key, text, learn: false, authorize: fn _n, _a, _c -> :once end)

  defp said?(key, text), do: Enum.any?(Session.history(key), &(to_string(&1["content"]) =~ text))

  describe "listing the turns" do
    test "each turn says how many files it changed, and a turn with none says zero", %{key: key} do
      ask(key, "WRITE a.md one")
      ask(key, "hello there")
      ask(key, "WRITE notes.md v2")

      assert [
               %{n: 1, preview: "WRITE notes.md v2", files: 1},
               %{n: 2, preview: "hello there", files: 0},
               %{n: 3, preview: "WRITE a.md one", files: 1}
             ] = Session.turns(key)
    end

    test "turns from before anything was tracked are unknown, not empty", %{key: key} do
      ask(key, "hello there")
      assert [%{n: 1, files: nil}] = Session.turns(key)
    end

    @tag checkpoints: false
    test "with checkpoints off nothing is claimed about files", %{key: key} do
      ask(key, "WRITE notes.md v2")
      assert [%{n: 1, files: nil}] = Session.turns(key)
    end
  end

  describe "rewinding conversation and files together" do
    test "the file goes back and the turn leaves the conversation", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")
      assert File.read!(notes) == "v2"

      assert {:ok, %{dropped: 1, files: report}} = Session.rewind_to(key, 1)

      assert report.restored == [notes]
      assert report.skipped == []
      assert File.read!(notes) == "original"
      refute said?(key, "WRITE notes.md v2")
    end

    test "a file the turn created is removed", %{key: key, workspace: ws} do
      ask(key, "WRITE fresh.md hello")
      assert File.exists?(Path.join(ws, "fresh.md"))

      assert {:ok, %{files: report}} = Session.rewind_to(key, 1)

      assert report.removed == [Path.join(ws, "fresh.md")]
      refute File.exists?(Path.join(ws, "fresh.md"))
    end

    test "only the turns asked for are undone, newest first", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")
      ask(key, "WRITE notes.md v3")

      assert {:ok, %{dropped: 1}} = Session.rewind_to(key, 1)
      assert File.read!(notes) == "v2"
      assert said?(key, "WRITE notes.md v2")

      assert {:ok, %{dropped: 1}} = Session.rewind_to(key, 1)
      assert File.read!(notes) == "original"
    end

    test "a file edited by hand afterwards is kept and reported", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")
      File.write!(notes, "my own edit")

      assert {:ok, %{dropped: 1, files: report}} = Session.rewind_to(key, 1)

      assert File.read!(notes) == "my own edit"
      assert [%{path: ^notes, reason: :changed_since}] = report.skipped
      assert report.restored == []
    end

    test "asking for more turns than exist reaches only the ones it can vouch for", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")

      assert {:ok, %{dropped: 1, files: report}} = Session.rewind_to(key, 5)
      assert report.restored == [notes]
      assert File.read!(notes) == "original"
    end
  end

  describe "the other two modes" do
    test "chat only drops the conversation, leaves the file, and counts what it left", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")

      assert {:ok, %{dropped: 1, files: nil, kept: 1}} = Session.rewind_to(key, 1, :chat)

      assert File.read!(notes) == "v2"
      refute said?(key, "WRITE notes.md v2")
    end

    test "files only puts the file back, keeps the conversation and tells the agent", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")
      turns_before = Session.status(key).turns

      assert {:ok, %{dropped: 0, files: report}} = Session.rewind_to(key, 1, :files)

      assert report.restored == [notes]
      assert File.read!(notes) == "original"
      assert Session.status(key).turns == turns_before
      # The agent is told, or it would go on believing its own write is still there.
      assert said?(key, "<system-reminder>")
    end

    test "files only, done twice, does not pretend the second time did anything", %{key: key} do
      ask(key, "WRITE notes.md v2")

      assert {:ok, %{files: %{restored: [_]}}} = Session.rewind_to(key, 1, :files)
      assert {:ok, %{files: second}} = Session.rewind_to(key, 1, :files)

      assert second.restored == []
    end
  end

  describe "/undo stays consistent with /rewind" do
    test "undo takes back the conversation only, exactly like a chat rewind", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")

      assert Session.undo(key) == :ok

      assert File.read!(notes) == "v2"
      refute said?(key, "WRITE notes.md v2")
      # The turn log followed the conversation, so the next turn lines up again.
      assert Session.turns(key) == []
    end

    test "a turn asked after an undo is listed against the right files", %{key: key} do
      ask(key, "WRITE notes.md v2")
      Session.undo(key)
      ask(key, "WRITE notes.md v3")

      assert [%{n: 1, preview: "WRITE notes.md v3", files: 1}] = Session.turns(key)
    end
  end

  describe "retrying" do
    test "hands back the last message and drops the turn, files untouched by default", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")

      assert {:ok, %{text: "WRITE notes.md v2", files: nil}} = Session.retry(key)

      assert File.read!(notes) == "v2"
      refute said?(key, "WRITE notes.md v2")
    end

    test "with files it puts them back first, so the retry starts from the same place", %{key: key, notes: notes} do
      ask(key, "WRITE notes.md v2")

      assert {:ok, %{text: "WRITE notes.md v2", files: report}} = Session.retry(key, :both)

      assert report.restored == [notes]
      assert File.read!(notes) == "original"
    end

    test "with nothing said yet there is nothing to retry", %{key: key} do
      assert Session.retry(key) == {:error, :nothing}
    end
  end

  describe "resetting" do
    test "a new conversation forgets the old turn log", %{key: key} do
      ask(key, "WRITE notes.md v2")
      Session.reset(key)

      assert Session.turns(key) == []
      assert {:ok, %{dropped: 0, files: files}} = Session.rewind_to(key, 1, :files)
      assert files.restored == []
    end
  end
end
