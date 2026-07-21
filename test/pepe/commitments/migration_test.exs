defmodule Pepe.Commitments.MigrationTest do
  @moduledoc """
  `Pepe.Commitments.Migration.run/0` - the one-time, operator-run import of commitments
  from config.json's old "commitments" section into `Pepe.Repo`. Deliberately not
  automatic (see its own moduledoc for why); these tests exercise it directly against a
  config.json written by hand, the same on-disk shape a pre-migration install would carry.
  """
  use ExUnit.Case, async: false

  alias Pepe.Commitments.Migration
  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_commit_migrate_#{System.unique_integer([:positive])}")
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

  defp write_legacy_commitments(entries) do
    Config.update(fn config -> Map.put(config, "commitments", entries) end)
  end

  test "nothing to migrate when config.json never had a commitments section" do
    report = Migration.run()
    assert report == %{imported: 0, already_present: 0, failed: []}
    assert Config.commitments() == []
  end

  test "imports every legacy entry and removes the config.json key" do
    write_legacy_commitments(%{
      "c_old1" => %{
        "text" => "renew the certificate",
        "agent" => "eng",
        "state" => "scheduled",
        "due_at" => 1_999_999_999,
        "origin" => %{"channel" => "telegram"},
        "confidence" => 0.9,
        "origin_type" => "agent_promise"
      },
      "c_old2" => %{
        "text" => "check the backups",
        "agent" => "eng",
        "state" => "awaiting_confirmation",
        "origin" => %{},
        "confidence" => 0.4,
        "origin_type" => "user_reminder"
      }
    })

    report = Migration.run()

    assert report == %{imported: 2, already_present: 0, failed: []}
    assert Config.load() |> Map.has_key?("commitments") == false

    ids = Config.commitments() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["c_old1", "c_old2"]

    imported = Config.get_commitment("c_old1")
    assert imported.text == "renew the certificate"
    assert imported.state == "scheduled"
    assert imported.due_at == 1_999_999_999
  end

  test "running it twice is a true no-op the second time" do
    write_legacy_commitments(%{
      "c_old1" => %{"text" => "renew the certificate", "agent" => "eng", "state" => "scheduled"}
    })

    assert Migration.run() == %{imported: 1, already_present: 0, failed: []}
    # config.json's key is gone now, so a second run has nothing left to look at.
    assert Migration.run() == %{imported: 0, already_present: 0, failed: []}
    assert length(Config.commitments()) == 1
  end

  test "resuming after a partial prior insert: already-present rows are skipped, not duplicated" do
    # Simulate a crash partway through a previous run: one row already made it into
    # Pepe.Repo (inserted directly, at the exact id an earlier `Migration.run/0` attempt
    # would have used - Config.create_commitment/1 always generates its own fresh id, so
    # it can't stand in for "this specific legacy id already made it across"), but
    # config.json's key was never cleared (that only happens after every row succeeds) -
    # so a fresh run still sees both entries in the raw config.
    %Config.Commitment{}
    |> Config.Commitment.changeset(%{id: "c_old1", text: "already migrated", agent: "eng"})
    |> Pepe.Repo.insert!()

    write_legacy_commitments(%{
      "c_old1" => %{"text" => "already migrated", "agent" => "eng"},
      "c_old2" => %{"text" => "still needs importing", "agent" => "eng"}
    })

    report = Migration.run()

    assert report == %{imported: 1, already_present: 1, failed: []}
    assert length(Config.commitments()) == 2
    # The row that was already there keeps its own original content, not overwritten.
    assert Config.get_commitment("c_old1").text == "already migrated"
  end

  test "a malformed entry is reported and the config.json key is not removed" do
    # A cast type mismatch (due_at must be an integer) forces a real changeset error.
    write_legacy_commitments(%{
      "c_good" => %{"text" => "a fine commitment", "agent" => "eng"},
      "c_bad" => %{"text" => "a broken one", "agent" => "eng", "due_at" => "not-a-number"}
    })

    report = Migration.run()

    assert report.imported == 1
    assert [{"c_bad", _reason}] = report.failed
    # Left in place - the operator can inspect/fix and re-run.
    assert Config.load() |> Map.has_key?("commitments")
    # The one good entry still isn't lost while the bad one is sorted out.
    assert Config.get_commitment("c_good").text == "a fine commitment"
  end
end
