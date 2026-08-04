defmodule Mix.Tasks.PepeBackupCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_bk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "data/mnesia"))
    File.mkdir_p!(Path.join(home, "agents/zak"))

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"telegram" => %{"bot_token" => "${TEST_BOT_TOKEN}"}})
    )

    File.write!(Path.join(home, "agents/zak/SOUL.md"), "I am Zak.")
    File.write!(Path.join(home, "data/mnesia/schema.DAT"), "junk")

    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()
    out = Path.join(System.tmp_dir!(), "bk_#{System.unique_integer([:positive])}.tgz")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      File.rm(out)
    end)

    {:ok, out: out}
  end

  test "backup archives the durable files, skips mnesia, and lists secret env vars", %{out: out} do
    output = capture_io(fn -> Mix.Tasks.Pepe.dispatch(["backup", "--output", out]) end)

    assert File.exists?(out)
    assert output =~ "TEST_BOT_TOKEN"
    assert output =~ "UNSET"

    entries = System.cmd("tar", ["tzf", out]) |> elem(0)
    assert entries =~ "config.json"
    assert entries =~ "agents/zak/SOUL.md"
    refute entries =~ "mnesia"
  end

  test "the database goes in as a verified snapshot, not a raw copy of the live file", %{out: out} do
    # Something real committed to the live db, so the archived copy is proven to be a
    # snapshot of actual data.
    Pepe.Config.Journal.put_source("backup-cli-test")

    output = capture_io(fn -> Mix.Tasks.Pepe.dispatch(["backup", "--output", out]) end)
    assert output =~ "database (verified snapshot)"

    entries = System.cmd("tar", ["tzf", out]) |> elem(0)
    assert entries =~ "data/pepe.db"
    refute entries =~ "pepe.db-wal"
    refute entries =~ "pepe.db-shm"

    stage = Path.join(System.tmp_dir!(), "pepe_bk_extract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(stage)
    System.cmd("tar", ["-xzf", out, "-C", stage])
    [home_dir] = File.ls!(stage)
    db = Path.join([stage, home_dir, "data", "pepe.db"])

    assert File.regular?(db)
    assert :ok = Pepe.Repo.Snapshot.integrity_check(db)

    File.rm_rf(stage)
  end

  test "backup verify reports pass on a good archive", %{out: out} do
    capture_io(fn -> Mix.Tasks.Pepe.dispatch(["backup", "--output", out]) end)

    output = capture_io(fn -> Mix.Tasks.Pepe.dispatch(["backup", "verify", out]) end)
    assert output =~ "passed integrity_check"
  end

  test "backup verify reports a missing archive plainly" do
    output = capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(["backup", "verify", "/no/such/archive.tgz"]) end)
    assert output =~ "no such archive"
  end
end
