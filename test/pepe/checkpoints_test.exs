defmodule Pepe.CheckpointsTest do
  use ExUnit.Case, async: false

  alias Pepe.Checkpoints.Snapshot
  alias Pepe.Checkpoints.Store

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_checkpoints_#{System.unique_integer([:positive])}")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{workspace: workspace}
  end

  test "snapshot diffs authored files while excluding secrets, symlinks and dependencies", %{workspace: workspace} do
    file = Path.join(workspace, "notes.txt")
    File.write!(file, "before")
    File.write!(Path.join(workspace, ".env"), "TOKEN=secret")
    File.mkdir_p!(Path.join(workspace, "node_modules"))
    File.write!(Path.join([workspace, "node_modules", "generated.js"]), "ignored")
    File.ln_s!(file, Path.join(workspace, "link"))

    before = Snapshot.take([workspace])
    File.write!(file, "after")
    File.write!(Path.join(workspace, "new.txt"), "new")
    after_snapshot = Snapshot.take([workspace])

    assert Enum.map(Snapshot.diff(before, after_snapshot), & &1.path) ==
             [Path.join(workspace, "new.txt"), Path.join(workspace, "notes.txt")]

    refute Map.has_key?(before.files, Path.join(workspace, ".env"))
    refute Map.has_key?(before.files, Path.join(workspace, "link"))
  end

  test "store validates identifiers and persists blobs, records and session logs", %{workspace: workspace} do
    sha = Store.put_blob("contents")
    assert {:ok, "contents"} = Store.get_blob(sha)
    assert :error = Store.get_blob("../bad")

    scope = Store.digest(workspace)
    id = Store.new_id()
    record = %{"id" => id, "changes" => []}
    assert :ok = Store.write_record(scope, workspace, record)
    assert {:ok, ^record} = Store.read_record(scope, id)
    assert [^id] = Store.record_ids(scope)
    assert Store.scope_path(scope) == workspace

    assert %{"turns" => [id]} =
             Store.update_log("session", fn log -> %{log | "turns" => [id]} end)

    assert %{"turns" => [^id], "pending" => []} = Store.read_log("session")
  end
end
