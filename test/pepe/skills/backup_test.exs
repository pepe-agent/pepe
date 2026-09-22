defmodule Pepe.Skills.BackupTest do
  @moduledoc """
  Snapshotting the skills tree and rolling it back, including the order-of-operations
  regression: `rollback/2` must never risk leaving `skills/` empty.
  """
  use ExUnit.Case, async: false

  alias Pepe.Skills
  alias Pepe.Skills.Backup
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage
  alias Pepe.Skills.Stats

  @doc_v1 "---\nname: x\ndescription: Use when x-ing.\n---\n\nDo the thing.\n"
  defp doc(name), do: String.replace(@doc_v1, "x", name)
  defp bg(run), do: [actor: "review", origin: :background, run: run]

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_backup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{dir: Path.join(home, "skills")}
  end

  defp write_skill(dir, name, body) do
    File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join([dir, name, "SKILL.md"]), body)
  end

  # Drops a `.tar.gz` straight into `Backup.dir()` under a hand-picked id, bypassing
  # `create/2` entirely so the test controls ordering deterministically (no sleeping for
  # `System.system_time/1` to tick over between snapshots).
  defp plant_snapshot(id, files) do
    File.mkdir_p!(Backup.dir())
    stage = Path.join(System.tmp_dir!(), "pepe_backup_plant_#{System.unique_integer([:positive])}")

    Enum.each(files, fn {rel, content} ->
      path = Path.join(stage, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    entries = stage |> File.ls!() |> Enum.map(&{String.to_charlist(&1), String.to_charlist(Path.join(stage, &1))})
    path = Path.join(Backup.dir(), id <> ".tar.gz")
    :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(stage)
  end

  test "rollback restores the target snapshot even though the pre-rollback snapshot it also takes would, on its own, prune the target away" do
    # `Backup.create/2`'s own `@keep = 10` retention: with exactly 10 snapshots already on
    # disk and `target` the oldest, the *next* snapshot taken (the "pre-rollback" one
    # `rollback/2` itself creates) pushes the count to 11, and `prune/0` drops the single
    # oldest to get back to 10 - which is `target`, the very thing being restored, unless
    # rollback reads it into safety before that snapshot is taken.
    plant_snapshot("1000-target", %{"restored/SKILL.md" => "restored content\n"})
    for n <- 1..9, do: plant_snapshot("#{1000 + n}-filler", %{"filler#{n}/SKILL.md" => "filler\n"})
    assert Enum.count_until(Backup.list(), 11) == 10

    assert {:ok, "1000-target"} = Backup.rollback("1000-target", "test")

    assert File.read!(Path.join([Pepe.Skills.user_dir(), "restored", "SKILL.md"])) == "restored content\n"
    refute File.exists?(Path.join(Pepe.Skills.user_dir(), "filler1"))
  end

  test "a rollback never leaves skills/ empty, even if the picked snapshot's tar has gone missing on disk", %{dir: dir} do
    write_skill(dir, "keep-me", "important\n")
    assert {:ok, id} = Backup.create("checkpoint", "test")

    snap = Enum.find(Backup.list(), &(&1.id == id))
    File.rm!(snap.path)

    assert {:error, _} = Backup.rollback(id, "test")
    assert File.read!(Path.join([dir, "keep-me", "SKILL.md"])) == "important\n"
  end

  test "rollback takes a pre-rollback snapshot of what was live, itself restorable", %{dir: dir} do
    write_skill(dir, "s", "old\n")
    assert {:ok, old} = Backup.create("checkpoint", "test")

    write_skill(dir, "s", "new\n")

    assert {:ok, ^old} = Backup.rollback(old, "test")
    assert File.read!(Path.join([dir, "s", "SKILL.md"])) == "old\n"

    pre = Enum.find(Backup.list(), &(&1.reason == "pre-rollback"))
    assert pre

    assert {:ok, _} = Backup.rollback(pre.id, "test")
    assert File.read!(Path.join([dir, "s", "SKILL.md"])) == "new\n"
  end

  test "rollback reconciles Stats.state to match where each skill actually ended up on disk" do
    assert {:ok, _} = Manage.create("was-live", doc("was-live"), bg("run-1"))
    assert {:ok, _} = Manage.create("was-archived", doc("was-archived"), bg("run-2"))
    assert {:ok, _} = Manage.delete("was-archived", bg("run-2"))

    # A snapshot where "was-live" is still on the shelf and "was-archived" already retired.
    assert {:ok, snap} = Backup.create("checkpoint", "test")

    # Now drift the other way: "was-live" gets archived, "was-archived" gets restored - the
    # opposite of what the snapshot above holds, so rolling back to it must flip both back.
    assert {:ok, _} = Manage.delete("was-live", bg("run-1"))
    assert {:ok, _} = Lifecycle.restore("was-archived", "test")
    Stats.set_state("was-archived", "active")
    assert Stats.get("was-live").state == "archived"
    assert Stats.get("was-archived").state == "active"

    assert {:ok, ^snap} = Backup.rollback(snap, "test")

    assert Stats.get("was-live").state == "active"
    assert Stats.get("was-archived").state == "archived"
  end

  test "rollback leaves no staging directory behind, success or failure", %{dir: dir} do
    write_skill(dir, "s", "v\n")
    assert {:ok, id} = Backup.create("checkpoint", "test")
    assert {:ok, ^id} = Backup.rollback(id, "test")

    refute File.exists?(Path.join(Path.dirname(Skills.user_dir()), ".rollback-staging"))

    assert {:error, _} = Backup.rollback("no-such-id", "test")
    refute File.exists?(Path.join(Path.dirname(Skills.user_dir()), ".rollback-staging"))
  end
end
