defmodule Pepe.Tools.SkillCuratorTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config.Agent
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stat
  alias Pepe.Tools.SkillCurator

  @day 86_400

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_skill_curator_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{dir: Path.join(home, "skills"), ctx: %{agent: %Agent{name: "worker"}}}
  end

  defp doc(name), do: "---\nname: #{name}\ndescription: Use when you need #{name}.\n---\n\nDo the thing.\n"

  defp agent_skill(name, days) do
    assert {:ok, _} = Manage.create(name, doc(name), actor: "review", origin: :background, run: "run-#{name}")
    then = System.system_time(:second) - days * @day
    Pepe.Repo.update_all(from(s in Stat, where: s.name == ^name), set: [created_at: then, last_patched_at: then])
  end

  defp person_skill(dir, name) do
    File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join([dir, name, "SKILL.md"]), doc(name))
  end

  defp call(ctx, args), do: SkillCurator.run(args, ctx)

  test "status and usage describe what is in its care", %{ctx: ctx} do
    agent_skill("old-one", 20)

    assert {:ok, status} = call(ctx, %{"action" => "status"})
    assert status =~ "curator: on"
    assert status =~ "1 skill(s) an agent wrote"

    assert {:ok, usage} = call(ctx, %{"action" => "usage"})
    assert usage =~ "old-one: active, idle 20d, used 0x"
  end

  test "run reports by default and changes nothing; a real run archives recoverably", %{ctx: ctx} do
    agent_skill("long-dead", 45)

    assert {:ok, msg} = call(ctx, %{"action" => "run"})
    assert msg =~ "Dry run, nothing changed: would mark 0 stale, archive 1"
    assert Ownership.origin("long-dead") == :agent

    assert {:ok, msg} = call(ctx, %{"action" => "run", "dry_run" => false})
    assert msg =~ "Done: 0 marked stale, 1 archived"
    assert Ownership.origin("long-dead") == :missing

    assert {:ok, "Restored long-dead" <> _} = call(ctx, %{"action" => "restore", "name" => "long-dead"})
    assert Ownership.origin("long-dead") == :agent
  end

  test "pause, resume and settings", %{ctx: ctx} do
    assert {:ok, _} = call(ctx, %{"action" => "pause"})
    assert State.paused?()
    assert {:ok, _} = call(ctx, %{"action" => "resume"})
    refute State.paused?()

    assert {:ok, "stale_after_days = 5"} = call(ctx, %{"action" => "settings", "key" => "stale_after_days", "value" => "5"})
    assert {:ok, listing} = call(ctx, %{"action" => "settings"})
    assert listing =~ "stale_after_days = 5"
    assert {:error, msg} = call(ctx, %{"action" => "settings", "key" => "stale_after_days", "value" => "999"})
    assert msg =~ "cannot be longer"
  end

  test "adopt, pin and release move a skill between the person and the curator", %{dir: dir, ctx: ctx} do
    person_skill(dir, "mine")

    assert {:error, msg} = call(ctx, %{"action" => "release", "name" => "mine"})
    assert msg =~ "not in the curator's care"

    assert {:ok, _} = call(ctx, %{"action" => "adopt", "name" => "mine"})
    assert Ownership.origin("mine") == :agent
    assert {:error, msg} = call(ctx, %{"action" => "adopt", "name" => "mine"})
    assert msg =~ "already in the curator's care"

    assert {:ok, _} = call(ctx, %{"action" => "pin", "name" => "mine"})
    refute Ownership.background_writable?("mine")
    assert {:ok, _} = call(ctx, %{"action" => "unpin", "name" => "mine"})
    assert {:ok, _} = call(ctx, %{"action" => "release", "name" => "mine"})
    assert Ownership.origin("mine") == :user

    assert {:error, _} = call(ctx, %{"action" => "adopt", "name" => "ghost"})
    assert {:error, _} = call(ctx, %{"action" => "pin", "name" => "ghost"})
  end

  test "log carries ids that undo accepts", %{ctx: ctx} do
    agent_skill("edited", 1)
    assert {:ok, %{entry: entry}} = Manage.patch("edited", "Do the thing.", "Do the thing well.", actor: "agent:test", origin: :foreground)

    assert {:ok, log} = call(ctx, %{"action" => "log", "name" => "edited"})
    assert log =~ entry
    assert {:ok, msg} = call(ctx, %{"action" => "undo", "id" => entry})
    assert msg =~ "edited"
    assert File.read!(Path.join([Pepe.Skills.user_dir(), "edited", "SKILL.md"])) =~ "Do the thing.\n"
    assert {:error, msg} = call(ctx, %{"action" => "undo", "id" => "nope"})
    assert msg =~ "no ledger entry"
  end

  test "a report can be read back", %{ctx: ctx} do
    assert {:error, "no such report"} = call(ctx, %{"action" => "report"})
    agent_skill("long-dead", 45)
    assert {:ok, _} = call(ctx, %{"action" => "run", "dry_run" => false})
    assert {:ok, text} = call(ctx, %{"action" => "report"})
    assert text =~ "long-dead: active to archived"
    assert {:ok, "long-dead" <> _} = call(ctx, %{"action" => "archived"})
    assert [_] = Lifecycle.archived()
  end

  test "it refuses to run inside an unattended run" do
    ctx = %{agent: %Agent{name: "worker"}, review_run: "run-x", review_actor: "curator"}
    assert {:error, msg} = SkillCurator.run(%{"action" => "status"}, ctx)
    assert msg =~ "unattended"
    assert Ledger.recent(5) == []
  end
end
