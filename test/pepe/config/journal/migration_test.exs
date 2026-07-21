defmodule Pepe.Config.Journal.MigrationTest do
  @moduledoc """
  `Pepe.Config.Journal.Migration.run/0` - the one-time, operator-run import of the old
  `data/config_journal.jsonl` file into `Pepe.Repo`. Unlike commitments/watches, entries
  have no natural id, so this only ever imports into an empty table - see its own
  moduledoc for why.
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

  test "the legacy file is never deleted, even after a successful import", %{home: home} do
    write_legacy_file(home, [%{"at" => 1, "source" => "cli", "changed" => [], "external" => false}])

    Migration.run()

    assert File.exists?(legacy_path(home))
  end

  test "refuses to run against a non-empty table, instead of risking a content-based dedupe" do
    Repo.insert!(%Entry{at: 1, source: "cli", changed: ["agents"], external: false})

    assert Migration.run() == {:error, :not_empty}
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
end
