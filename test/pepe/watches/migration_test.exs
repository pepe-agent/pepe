defmodule Pepe.Watches.MigrationTest do
  @moduledoc """
  `Pepe.Watches.Migration.run/0` - the one-time, operator-run import of watches from
  config.json's old "watches" section into `Pepe.Repo`. Mirrors
  `Pepe.Commitments.MigrationTest` exactly - same shape, same edge cases.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Watches.Migration

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_watch_migrate_#{System.unique_integer([:positive])}")
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

  defp write_legacy_watches(entries) do
    Config.update(fn config -> Map.put(config, "watches", entries) end)
  end

  test "nothing to migrate when config.json never had a watches section" do
    report = Migration.run()
    assert report == %{imported: 0, already_present: 0, failed: []}
    assert Config.watches() == []
  end

  test "imports every legacy entry and removes the config.json key" do
    write_legacy_watches(%{
      "w_old1" => %{
        "description" => "site is back up",
        "agent" => "eng",
        "trigger" => %{"type" => "probe", "command" => "curl -sf https://x"},
        "state" => "pending"
      },
      "w_old2" => %{
        "description" => "deploy finished",
        "agent" => "eng",
        "trigger" => %{"type" => "agent", "prompt" => "has it finished?"},
        "state" => "paused"
      }
    })

    report = Migration.run()

    assert report == %{imported: 2, already_present: 0, failed: []}
    assert Config.load() |> Map.has_key?("watches") == false

    ids = Config.watches() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["w_old1", "w_old2"]

    imported = Config.get_watch("w_old1")
    assert imported.description == "site is back up"
    assert imported.state == "pending"
    assert imported.trigger == %{"type" => "probe", "command" => "curl -sf https://x"}
  end

  test "running it twice is a true no-op the second time" do
    write_legacy_watches(%{"w_old1" => %{"description" => "x", "agent" => "eng"}})

    assert Migration.run() == %{imported: 1, already_present: 0, failed: []}
    assert Migration.run() == %{imported: 0, already_present: 0, failed: []}
    assert length(Config.watches()) == 1
  end

  test "resuming after a partial prior insert: already-present rows are skipped, not duplicated" do
    %Config.Watch{}
    |> Config.Watch.changeset(%{id: "w_old1", description: "already migrated", agent: "eng"})
    |> Pepe.Repo.insert!()

    write_legacy_watches(%{
      "w_old1" => %{"description" => "already migrated", "agent" => "eng"},
      "w_old2" => %{"description" => "still needs importing", "agent" => "eng"}
    })

    report = Migration.run()

    assert report == %{imported: 1, already_present: 1, failed: []}
    assert length(Config.watches()) == 2
    assert Config.get_watch("w_old1").description == "already migrated"
  end

  test "a malformed entry is reported and the config.json key is not removed" do
    # A cast type mismatch (interval_s must be an integer) forces a real changeset error.
    write_legacy_watches(%{
      "w_good" => %{"description" => "a fine watch", "agent" => "eng"},
      "w_bad" => %{"description" => "a broken one", "agent" => "eng", "interval_s" => "not-a-number"}
    })

    report = Migration.run()

    assert report.imported == 1
    assert [{"w_bad", _reason}] = report.failed
    assert Config.load() |> Map.has_key?("watches")
    assert Config.get_watch("w_good").description == "a fine watch"
  end

  test "an entry whose value isn't even a map is reported, not a crash" do
    write_legacy_watches(%{
      "w_good" => %{"description" => "a fine watch", "agent" => "eng"},
      "w_weird" => "not even a map"
    })

    report = Migration.run()

    assert report.imported == 1
    assert [{"w_weird", _reason}] = report.failed
    assert Config.load() |> Map.has_key?("watches")
  end
end
