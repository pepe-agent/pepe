defmodule Pepe.Tools.EditFileTest do
  @moduledoc """
  `edit_file` is the agent's most-used mutation tool, and had zero dedicated coverage: nothing
  asserted on a real replace, an ambiguous/missing old_string, or how it behaves at the workspace
  boundary. Path *authorization* for an out-of-workspace target (absolute, `..`, `shared/`) is the
  permission gate's job (see permissions_risk_test.exs) - this file covers what the tool itself
  does once a call actually reaches it: replace correctness, error cases, and that it resolves
  through Workspace like every other file tool (see workspace_test.exs for resolution itself).
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Tools.EditFile

  @ctx %{agent: %{name: "assistant"}}

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_editfile_#{System.unique_integer([:positive])}")
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

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  test "replaces a unique substring and leaves the rest untouched", %{dir: dir} do
    write(dir, "note.md", "line one\nold text\nline three")

    assert {:ok, msg} = EditFile.run(%{"path" => "note.md", "old_string" => "old text", "new_string" => "new text"}, @ctx)
    assert msg =~ "edited"
    assert File.read!(Path.join(dir, "note.md")) == "line one\nnew text\nline three"
  end

  test "only the first (and only) match is required to be unique - a literal-string replace, not regex", %{dir: dir} do
    write(dir, "note.md", "cost: $5.00 (was $5.00 before)")

    # "$5.00" appears twice - this must be refused, not silently pick one.
    assert {:error, msg} = EditFile.run(%{"path" => "note.md", "old_string" => "$5.00", "new_string" => "$6.00"}, @ctx)
    assert msg =~ "found 2 times"
    assert msg =~ "must be unique"
    # unmodified
    assert File.read!(Path.join(dir, "note.md")) == "cost: $5.00 (was $5.00 before)"
  end

  test "old_string not present is refused, file unmodified", %{dir: dir} do
    write(dir, "note.md", "hello world")

    assert {:error, "old_string not found"} =
             EditFile.run(%{"path" => "note.md", "old_string" => "goodbye", "new_string" => "x"}, @ctx)

    assert File.read!(Path.join(dir, "note.md")) == "hello world"
  end

  test "a missing file reports a clear error instead of an Elixir File.read tuple", %{dir: dir} do
    missing = Path.join(dir, "nope.md")
    assert {:error, msg} = EditFile.run(%{"path" => "nope.md", "old_string" => "x", "new_string" => "y"}, @ctx)
    assert msg =~ "file not found"
    assert msg =~ missing
  end

  test "a non-string path is rejected before touching the filesystem" do
    assert {:error, "'path' must be a string"} =
             EditFile.run(%{"path" => 123, "old_string" => "x", "new_string" => "y"}, @ctx)
  end

  test "missing required args are rejected with a clear message" do
    assert {:error, msg} = EditFile.run(%{"path" => "note.md"}, @ctx)
    assert msg =~ "missing"
  end

  test "a relative path resolves inside the agent's own workspace, not the cwd", %{dir: dir} do
    write(dir, "note.md", "before")
    EditFile.run(%{"path" => "note.md", "old_string" => "before", "new_string" => "after"}, @ctx)

    # Landed in Workspace.dir("assistant"), nowhere else.
    assert File.read!(Path.join(dir, "note.md")) == "after"
  end

  test "shared/... resolves into the shared space, reachable from another agent too" do
    shared_path = Path.join(Workspace.shared_dir(), "team.md")
    File.mkdir_p!(Path.dirname(shared_path))
    File.write!(shared_path, "shared before")

    other_ctx = %{agent: %{name: "sales"}}
    assert {:ok, _} = EditFile.run(%{"path" => "shared/team.md", "old_string" => "before", "new_string" => "after"}, other_ctx)
    assert File.read!(shared_path) == "shared after"
  end
end
