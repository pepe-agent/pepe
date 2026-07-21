defmodule Pepe.Usage.MigrationTest do
  @moduledoc """
  `Pepe.Usage.Migration.run/0` - the one-time, operator-run import of the old
  `data/usage/<project>/YYYY-MM.jsonl` and `data/messages/<project>/YYYY-MM.jsonl`
  ledgers into `Pepe.Repo`. Unlike commitments/watches/traces, entries have no natural
  id, so this only ever imports into empty tables - see its own moduledoc for why.
  """
  use ExUnit.Case, async: false

  alias Pepe.Repo
  alias Pepe.Usage.Entry
  alias Pepe.Usage.Log
  alias Pepe.Usage.MessageEvent
  alias Pepe.Usage.Messages
  alias Pepe.Usage.Migration

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_usage_migrate_#{System.unique_integer([:positive])}")
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

  defp write_legacy_usage(scope, filename, lines) do
    dir = Log.scope_dir(scope)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  defp write_legacy_messages(scope, filename, lines) do
    dir = Messages.scope_dir(scope)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  test "nothing to migrate when no legacy files exist" do
    assert Migration.run() == %{
             usage_entries: %{imported: 0, failed: []},
             message_events: %{imported: 0, failed: []}
           }
  end

  test "imports every legacy usage entry and message event, across scopes" do
    write_legacy_usage("acme", "2026-07.jsonl", [
      %{"at" => 1, "agent" => "acme/sales", "model" => "m", "in" => 10, "out" => 5}
    ])

    write_legacy_messages("acme", "2026-07.jsonl", [%{"at" => 1}, %{"at" => 2, "reset" => true}])

    report = Migration.run()

    assert report.usage_entries == %{imported: 1, failed: []}
    assert report.message_events == %{imported: 2, failed: []}

    assert [%Entry{project: "acme", agent: "acme/sales", in: 10, out: 5}] = Repo.all(Entry)
    events = Repo.all(MessageEvent) |> Enum.sort_by(& &1.at)
    assert [%{reset: false}, %{reset: true}] = events
  end

  test "never deletes the legacy source files, even after a successful import" do
    write_legacy_usage("acme", "2026-07.jsonl", [%{"at" => 1, "agent" => "a", "model" => "m", "in" => 1, "out" => 1}])

    Migration.run()

    assert File.exists?(Path.join(Log.scope_dir("acme"), "2026-07.jsonl"))
  end

  test "refuses to run against non-empty tables, instead of risking a content-based dedupe" do
    Repo.insert!(%Entry{project: "acme", at: 1, in: 1, out: 1})
    Repo.insert!(%MessageEvent{project: "acme", at: 1})

    assert Migration.run() == %{usage_entries: {:error, :not_empty}, message_events: {:error, :not_empty}}
  end

  test "one table refusing does not block the other from importing" do
    Repo.insert!(%Entry{project: "acme", at: 1, in: 1, out: 1})
    write_legacy_messages("acme", "2026-07.jsonl", [%{"at" => 1}])

    report = Migration.run()

    assert report.usage_entries == {:error, :not_empty}
    assert report.message_events == %{imported: 1, failed: []}
  end

  test "a malformed legacy file is reported, the well-formed ones still import" do
    write_legacy_usage("acme", "2026-07.jsonl", [%{"at" => 1, "agent" => "a", "model" => "m", "in" => 1, "out" => 1}])
    File.write!(Path.join(Log.scope_dir("acme"), "bad.jsonl"), "not even json\n")

    report = Migration.run()

    assert report.usage_entries.imported == 1
    assert [{_path, _reason}] = report.usage_entries.failed
  end
end
