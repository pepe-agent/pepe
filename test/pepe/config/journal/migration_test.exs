defmodule Pepe.Config.Journal.MigrationTest do
  @moduledoc """
  `Pepe.Config.Journal.Migration.run/0` - the one-time, operator-run import of the old
  `data/config_journal.jsonl` file into `Pepe.Repo`. Unlike commitments/watches, entries
  have no natural id, so idempotency is keyed on the source file's presence (renamed away
  on success), not on the table's row count - see its own moduledoc for why.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Journal.Entry
  alias Pepe.Config.Journal.Migration
  alias Pepe.Repo

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_journal_migrate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp legacy_path(home), do: Path.join([home, "data", "config_journal.jsonl"])

  defp write_legacy_file(home, lines) do
    path = legacy_path(home)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  test "nothing to migrate when no legacy file exists", %{home: _home} do
    assert Migration.run() == %{imported: 0, failed: []}
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "imports every legacy line", %{home: home} do
    write_legacy_file(home, [
      %{"at" => 1_700_000_000, "source" => "cli", "changed" => ["agents"], "external" => false},
      %{"at" => 1_700_000_010, "source" => "dashboard", "changed" => ["models"], "external" => true}
    ])

    report = Migration.run()

    assert report == %{imported: 2, failed: []}
    entries = Repo.all(Entry) |> Enum.sort_by(& &1.at)
    assert [%{source: "cli", external: false}, %{source: "dashboard", external: true}] = entries
  end

  test "the legacy file is renamed, not deleted, after a successful import", %{home: home} do
    write_legacy_file(home, [%{"at" => 1, "source" => "cli", "changed" => [], "external" => false}])

    Migration.run()

    refute File.exists?(legacy_path(home))
    assert File.read!(legacy_path(home) <> ".imported") =~ ~s("source":"cli")
  end

  test "a retry after a successful import is a safe, instant no-op", %{home: home} do
    write_legacy_file(home, [%{"at" => 1, "source" => "cli", "changed" => [], "external" => false}])

    assert Migration.run() == %{imported: 1, failed: []}
    assert Migration.run() == %{imported: 0, failed: []}
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "unrelated rows already in the table (ordinary app usage, or another subsystem's own migration writing to config in the same run) do not block a legacy import that never actually ran",
       %{home: home} do
    write_legacy_file(home, [%{"at" => 1, "source" => "cli", "changed" => [], "external" => false}])
    Repo.insert!(%Entry{at: 999, source: "unrelated", changed: ["agents"], external: false})

    assert Migration.run() == %{imported: 1, failed: []}
    assert Repo.aggregate(Entry, :count) == 2
  end

  test "a malformed line is reported, the well-formed ones still import", %{home: home} do
    File.mkdir_p!(Path.join(home, "data"))

    File.write!(
      legacy_path(home),
      Jason.encode!(%{"at" => 1, "source" => "cli", "changed" => [], "external" => false}) <> "\nnot even json\n"
    )

    report = Migration.run()

    assert report.imported == 1
    assert [{:malformed_line, "not even json"}] = report.failed
  end

  test "a line missing at/source, or with the wrong type for either, is reported instead of crashing at insert", %{
    home: home
  } do
    write_legacy_file(home, [
      %{"at" => 1, "source" => "cli", "changed" => [], "external" => false},
      %{"source" => "cli", "changed" => []},
      %{"at" => "not-a-number", "source" => "cli", "changed" => []},
      %{"at" => 2, "source" => nil, "changed" => []}
    ])

    report = Migration.run()

    assert report.imported == 1
    assert length(report.failed) == 3
  end

  test "importing a large journal (past SQLite's bind-parameter ceiling) still works", %{home: home} do
    # This schema has 4 columns; a single unchunked insert_all hits SQLite's ?1..?32766
    # ceiling well under 10000 rows - this pins the fix.
    lines = for i <- 1..10_000, do: %{"at" => i, "source" => "cli", "changed" => ["agents"], "external" => false}
    write_legacy_file(home, lines)

    report = Migration.run()

    assert report == %{imported: 10_000, failed: []}
    assert Repo.aggregate(Entry, :count) == 10_000
  end
end
