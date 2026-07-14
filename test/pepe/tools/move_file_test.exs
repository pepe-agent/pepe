defmodule Pepe.Tools.MoveFileTest do
  @moduledoc """
  `move_file` had zero dedicated coverage. Path *authorization* for an out-of-workspace target is
  the permission gate's job (see permissions_risk_test.exs, which covers `move_file`'s two-path
  risk hints specifically) - this file covers the tool's own behavior: a successful move/rename,
  destination directories created on demand, and clear errors when the source is missing.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Tools.MoveFile

  @ctx %{agent: %{name: "assistant"}}

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_movefile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    dir = Workspace.dir("assistant")
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  test "renames a file within the workspace", %{dir: dir} do
    File.write!(Path.join(dir, "old.md"), "content")

    assert {:ok, msg} = MoveFile.run(%{"from" => "old.md", "to" => "new.md"}, @ctx)
    assert msg =~ "moved"
    refute File.exists?(Path.join(dir, "old.md"))
    assert File.read!(Path.join(dir, "new.md")) == "content"
  end

  test "moving into a subdirectory that doesn't exist yet creates it", %{dir: dir} do
    File.write!(Path.join(dir, "note.md"), "x")

    assert {:ok, _} = MoveFile.run(%{"from" => "note.md", "to" => "notes/2026/note.md"}, @ctx)
    assert File.read!(Path.join(dir, "notes/2026/note.md")) == "x"
  end

  test "moving a directory moves everything inside it", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "drafts"))
    File.write!(Path.join(dir, "drafts/a.md"), "a")
    File.write!(Path.join(dir, "drafts/b.md"), "b")

    assert {:ok, _} = MoveFile.run(%{"from" => "drafts", "to" => "archive"}, @ctx)
    refute File.exists?(Path.join(dir, "drafts"))
    assert File.read!(Path.join(dir, "archive/a.md")) == "a"
    assert File.read!(Path.join(dir, "archive/b.md")) == "b"
  end

  test "a missing source reports a clear error instead of an Elixir error tuple" do
    assert {:error, msg} = MoveFile.run(%{"from" => "nope.md", "to" => "elsewhere.md"}, @ctx)
    assert msg =~ "cannot move"
    assert msg =~ "nope.md"
  end

  test "non-string from/to is rejected before touching the filesystem" do
    assert {:error, "'from' and 'to' must be strings"} = MoveFile.run(%{"from" => 1, "to" => "x"}, @ctx)
  end

  test "missing required args are rejected with a clear message" do
    assert {:error, msg} = MoveFile.run(%{"from" => "x.md"}, @ctx)
    assert msg =~ "missing"
  end

  test "shared/... resolves into the shared space, reachable from another agent too" do
    shared_dir = Workspace.shared_dir()
    File.mkdir_p!(shared_dir)
    File.write!(Path.join(shared_dir, "draft.md"), "team notes")

    other_ctx = %{agent: %{name: "sales"}}
    assert {:ok, _} = MoveFile.run(%{"from" => "shared/draft.md", "to" => "shared/final.md"}, other_ctx)
    assert File.read!(Path.join(shared_dir, "final.md")) == "team notes"
  end
end
