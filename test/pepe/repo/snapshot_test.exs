defmodule Pepe.Repo.SnapshotTest do
  use ExUnit.Case, async: false

  alias Pepe.Repo.Snapshot

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_snap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  test "vacuum_into/1 produces a snapshot that passes integrity_check/1 and carries committed data", %{home: home} do
    # Something real in the live database, so the snapshot is proven to be a copy of actual
    # data, not just an empty file that happens to pass the check.
    Pepe.Config.Journal.put_source("snapshot-test")

    dest = Path.join(home, "snap.db")
    assert :ok = Snapshot.vacuum_into(dest)
    assert File.exists?(dest)
    assert :ok = Snapshot.integrity_check(dest)
  end

  test "vacuum_into/1 refuses to overwrite an existing file" do
    dest = Path.join(System.tmp_dir!(), "pepe_snap_exists_#{System.unique_integer([:positive])}.db")
    File.write!(dest, "not a database")
    on_exit(fn -> File.rm(dest) end)

    assert {:error, _reason} = Snapshot.vacuum_into(dest)
  end

  test "integrity_check/1 reports a corrupt/non-database file as failing, not crashing" do
    bogus = Path.join(System.tmp_dir!(), "pepe_snap_bogus_#{System.unique_integer([:positive])}.db")
    File.write!(bogus, "this is not a sqlite file, just plain bytes")
    on_exit(fn -> File.rm(bogus) end)

    assert {:error, _reason} = Snapshot.integrity_check(bogus)
  end

  test "integrity_check/1 on a missing file errors instead of crashing" do
    assert {:error, _reason} =
             Snapshot.integrity_check(Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}.db"))
  end
end
