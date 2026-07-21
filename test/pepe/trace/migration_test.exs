defmodule Pepe.Trace.MigrationTest do
  @moduledoc """
  `Pepe.Trace.Migration.run/0` - the one-time, operator-run import of the old
  `data/traces/<scope>/<id>.json` file tree into `Pepe.Repo`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Repo
  alias Pepe.Trace
  alias Pepe.Trace.Migration

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_trace_migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp write_legacy_trace(scope, id, attrs) do
    dir = Trace.scope_dir(scope)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{id}.json"), Jason.encode!(Map.put(attrs, "id", id)))
  end

  test "nothing to migrate when no legacy trace tree exists" do
    assert Migration.run() == %{imported: 0, already_present: 0, failed: []}
  end

  test "imports every legacy trace file across every scope" do
    write_legacy_trace("default", "t1", %{
      "at" => 1_700_000_000,
      "agent" => "assistant",
      "prompt" => "hi",
      "outcome" => %{"kind" => "ok"},
      "events" => [%{"t" => "assistant", "text" => "hi back"}]
    })

    write_legacy_trace("acme", "t2", %{
      "at" => 1_700_000_010,
      "agent" => "acme/bot",
      "outcome" => %{"kind" => "ok"},
      "events" => []
    })

    report = Migration.run()

    assert report == %{imported: 2, already_present: 0, failed: []}
    assert Trace.get("default", "t1")["prompt"] == "hi"
    assert Trace.get("acme", "t2")["agent"] == "acme/bot"
  end

  test "running it twice is a true no-op the second time" do
    write_legacy_trace("default", "t1", %{"at" => 1, "outcome" => %{}, "events" => []})

    assert Migration.run() == %{imported: 1, already_present: 0, failed: []}
    assert Migration.run() == %{imported: 0, already_present: 1, failed: []}
  end

  test "never deletes the legacy source files, even after a successful import" do
    write_legacy_trace("default", "t1", %{"at" => 1, "outcome" => %{}, "events" => []})

    Migration.run()

    assert File.exists?(Path.join(Trace.scope_dir("default"), "t1.json"))
  end

  test "resuming after a partial prior insert: already-present ids are skipped, not duplicated" do
    Repo.insert_all(Pepe.Trace.Entry, [%{id: "t1", scope: "default", at: 1, outcome: %{}, events: []}])
    write_legacy_trace("default", "t1", %{"at" => 1, "outcome" => %{}, "events" => []})
    write_legacy_trace("default", "t2", %{"at" => 2, "outcome" => %{}, "events" => []})

    report = Migration.run()

    assert report == %{imported: 1, already_present: 1, failed: []}
  end

  test "a malformed legacy file is reported, the well-formed ones still import" do
    write_legacy_trace("default", "t1", %{"at" => 1, "outcome" => %{}, "events" => []})

    dir = Trace.scope_dir("default")
    File.write!(Path.join(dir, "t_bad.json"), "not even json")

    report = Migration.run()

    assert report.imported == 1
    assert [{"default/t_bad", _reason}] = report.failed
  end
end
