defmodule Mix.Tasks.PepeSkillCuratorCliTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Manage
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stat

  @day 86_400

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_curator_cli_#{System.unique_integer([:positive])}")
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

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  defp agent_skill(name, days) do
    doc = "---\nname: #{name}\ndescription: Use when you need #{name}.\n---\n\nDo the thing.\n"
    assert {:ok, _} = Manage.create(name, doc, actor: "review", origin: :background, run: "run-#{name}")
    then = System.system_time(:second) - days * @day
    Pepe.Repo.update_all(from(s in Stat, where: s.name == ^name), set: [created_at: then, last_patched_at: then])
  end

  test "status says what the curator is and is not doing" do
    agent_skill("old-one", 20)

    out = pepe(["skill", "curator", "status"])
    assert out =~ "curator: on"
    assert out =~ "last run: never"
    assert out =~ "old-one"

    pepe(["skill", "curator", "pause"])
    assert pepe(["skill", "curator", "status"]) =~ "curator: paused"
    pepe(["skill", "curator", "resume"])
    refute State.paused?()
  end

  test "run --dry-run reports without changing, run archives, and archived/restore round-trip" do
    agent_skill("long-dead", 45)

    out = pepe(["skill", "curator", "run", "--dry-run"])
    assert out =~ "would mark 0 stale, archive 1"
    assert Ownership.origin("long-dead") == :agent

    out = pepe(["skill", "curator", "run"])
    assert out =~ "0 marked stale, 1 archived"
    assert out =~ "rollback"
    assert pepe(["skill", "archived"]) =~ "long-dead"

    assert pepe(["skill", "restore", "long-dead"]) =~ "restored long-dead"
    assert pepe(["skill", "archived"]) =~ "No archived skills."
  end

  test "usage, reports and report" do
    agent_skill("long-dead", 45)
    assert pepe(["skill", "curator", "usage"]) =~ "long-dead"
    assert pepe(["skill", "curator", "reports"]) =~ "No curator reports yet."
    assert pepe_err(["skill", "curator", "report"]) =~ "no such report"

    pepe(["skill", "curator", "run"])
    assert [id] = Pepe.Skills.Curator.reports()
    assert pepe(["skill", "curator", "reports"]) =~ id
    assert pepe(["skill", "curator", "report"]) =~ "long-dead: active to archived"
    assert pepe(["skill", "curator", "report", id]) =~ "Curator run"
    assert pepe_err(["skill", "curator", "report", "../etc/passwd"]) =~ "no such report"
  end

  test "settings and set validate" do
    assert pepe(["skill", "curator", "settings"]) =~ "stale_after_days = 14"
    assert pepe(["skill", "curator", "set", "stale_after_days", "5"]) =~ "stale_after_days = 5"
    assert Settings.stale_after_days() == 5
    assert pepe_err(["skill", "curator", "set", "stale_after_days", "99"]) =~ "cannot be longer"
    assert pepe_err(["skill", "curator", "set", "bogus", "1"]) =~ "unknown curator setting"
  end

  test "log shows ids and undo puts a change back", %{dir: dir} do
    agent_skill("edited", 1)
    assert {:ok, %{entry: id}} = Manage.patch("edited", "Do the thing.", "Do it well.", actor: "user:test", origin: :foreground)

    assert pepe(["skill", "log", "edited"]) =~ id
    assert pepe(["skill", "undo", id]) =~ "edited"
    assert File.read!(Path.join([dir, "edited", "SKILL.md"])) =~ "Do the thing."
    assert pepe_err(["skill", "undo", "nope"]) =~ "no ledger entry"
    assert Enum.any?(Ledger.recent(10, "edited"), &(&1.action == "patch"))
  end

  test "adopt, pin, release and unmanaged", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "mine"))
    File.write!(Path.join([dir, "mine", "SKILL.md"]), "---\nname: mine\ndescription: Use when mine.\n---\n\nBody.\n")

    assert pepe(["skill", "unmanaged"]) =~ "mine"
    assert pepe(["skill", "adopt", "mine"]) =~ "adopted mine"
    refute pepe(["skill", "unmanaged"]) =~ "mine"
    assert pepe_err(["skill", "adopt", "mine"]) =~ "already in the curator's care"
    assert pepe(["skill", "pin", "mine"]) =~ "pinned mine"
    assert pepe(["skill", "unpin", "mine"]) =~ "unpinned mine"
    assert pepe(["skill", "release", "mine"]) =~ "released mine"
    assert pepe_err(["skill", "release", "mine"]) =~ "not in the curator's care"
    assert pepe_err(["skill", "adopt", "ghost"]) =~ "no skill of yours"
  end

  test "an unknown curator subcommand prints the usage" do
    assert pepe_err(["skill", "curator", "wat"]) =~ "usage: mix pepe skill curator"
  end
end
