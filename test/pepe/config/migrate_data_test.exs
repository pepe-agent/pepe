defmodule Pepe.Config.MigrateDataTest do
  @moduledoc """
  `Pepe.Config.MigrateData.run/0` - the orchestrator behind `mix pepe config
  migrate-data` that runs every remaining subsystem's own migration module in one go.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Journal.Entry
  alias Pepe.Config.MigrateData
  alias Pepe.Repo

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_migrate_data_#{System.unique_integer([:positive])}")
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

  @empty_usage %{
    usage_entries: %{imported: 0, failed: []},
    message_events: %{imported: 0, failed: []}
  }

  test "nothing to migrate anywhere" do
    assert MigrateData.run() == [
             config_journal: %{imported: 0, failed: []},
             watches: %{imported: 0, already_present: 0, failed: []},
             traces: %{imported: 0, already_present: 0, failed: []},
             boards: %{imported: 0, already_present: 0, failed: []},
             usage: @empty_usage
           ]
  end

  # Config.save/1 (not Config.update/1) so this seed itself doesn't land a real entry in
  # the config journal - that would trip its own "non-empty table" gate below and muddy
  # what this test is actually checking. See the last test for that gate on its own.
  defp seed_legacy_watches(entries), do: Config.save(Map.put(Config.load(), "watches", entries))

  test "runs every subsystem, in a fixed order, and one succeeding doesn't depend on the others" do
    seed_legacy_watches(%{"w1" => %{"description" => "x", "agent" => "eng"}})

    assert MigrateData.run() == [
             config_journal: %{imported: 0, failed: []},
             watches: %{imported: 1, already_present: 0, failed: []},
             traces: %{imported: 0, already_present: 0, failed: []},
             boards: %{imported: 0, already_present: 0, failed: []},
             usage: @empty_usage
           ]
  end

  test "one subsystem refusing (non-empty table) does not block the others from importing" do
    Repo.insert!(%Pepe.Usage.Entry{project: "acme", at: 1, agent: "eng", model: "m", in: 1, out: 1, sub: false, cached: 0})
    seed_legacy_watches(%{"w1" => %{"description" => "x", "agent" => "eng"}})

    results = MigrateData.run() |> Map.new()

    assert results.config_journal == %{imported: 0, failed: []}
    assert results.watches == %{imported: 1, already_present: 0, failed: []}
    assert results.traces == %{imported: 0, already_present: 0, failed: []}
    assert results.boards == %{imported: 0, already_present: 0, failed: []}
    assert results.usage.usage_entries == {:error, :not_empty}
  end

  # config_journal is deliberately not gated on the table being empty (see its own
  # migration moduledoc): Journal.record/4 writes to this exact table on every ordinary
  # config write, with or without this command ever running, so any real install is
  # likely to already have unrelated rows here by the time an operator gets around to
  # running migrate-data.
  test "unrelated rows already in the journal table (from ordinary app usage before this ever ran) don't block importing the legacy journal file" do
    home = System.get_env("PEPE_HOME")
    File.mkdir_p!(Path.join(home, "data"))
    File.write!(Path.join([home, "data", "config_journal.jsonl"]), Jason.encode!(%{"at" => 1, "source" => "cli", "changed" => []}) <> "\n")
    Repo.insert!(%Entry{at: 999, source: "unrelated", changed: ["agents"], external: false})
    seed_legacy_watches(%{"w1" => %{"description" => "x", "agent" => "eng"}})

    results = MigrateData.run() |> Map.new()

    assert results.config_journal == %{imported: 1, failed: []}
    assert results.watches == %{imported: 1, already_present: 0, failed: []}
  end
end
