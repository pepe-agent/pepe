defmodule Pepe.Skills.CuratorTest do
  @moduledoc """
  The curator: which skills it may touch, the deterministic stale/archive pass and its
  reversibility, the report and snapshot a run leaves, when a run is due, and the model pass
  that merges skills (through `skill_manage`, so it is owned and in the ledger).
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Repo
  alias Pepe.Skills.Curator
  alias Pepe.Skills.Curator.Consolidate
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stat
  alias Pepe.Skills.Stats
  alias Pepe.Usage.Run

  @day 86_400

  defmodule ScriptedPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      Elixir.Agent.update(:curator_requests, &[raw | &1])

      message =
        case Elixir.Agent.get_and_update(:curator_script, fn
               [next | rest] -> {next, rest}
               [] -> {nil, []}
             end) do
          nil -> %{"role" => "assistant", "content" => "merged them"}
          calls -> %{"role" => "assistant", "content" => nil, "tool_calls" => calls}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_curator_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :curator_script)
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :curator_requests)
    {:ok, server} = Bandit.start_link(plug: ScriptedPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home, dir: Path.join(home, "skills")}
  end

  defp doc(name, body \\ "Do the thing."), do: "---\nname: #{name}\ndescription: Use when you need #{name}.\n---\n\n#{body}\n"

  # A skill the background review wrote (agent-owned), whose last activity was `days` ago.
  defp agent_skill(name, days) do
    assert {:ok, _} = Manage.create(name, doc(name), actor: "review", origin: :background, run: "run-#{name}")
    age(name, days)
  end

  defp age(name, days) do
    then = System.system_time(:second) - days * @day

    Repo.update_all(from(s in Stat, where: s.name == ^name),
      set: [created_at: then, last_patched_at: then, last_used_at: nil, last_viewed_at: nil]
    )
  end

  defp person_skill(dir, name, days) do
    File.mkdir_p!(Path.join(dir, name))
    File.write!(Path.join([dir, name, "SKILL.md"]), doc(name))
    Stats.record_created(name, "user:cli", false)
    age(name, days)
  end

  defp state_of(name), do: Stats.get(name).state
  defp script(batches), do: Elixir.Agent.update(:curator_script, fn _ -> batches end)

  describe "what it may touch" do
    test "only agent-written, unpinned, not auto-loaded, not archived skills", %{dir: dir} do
      agent_skill("mine-a", 0)
      agent_skill("pinned-one", 0)
      agent_skill("auto-one", 0)
      agent_skill("gone", 0)
      person_skill(dir, "hand-written", 0)
      Stats.pin("pinned-one", true)
      Pepe.Skills.Settings.add_auto_load("auto-one")
      assert {:ok, _} = Lifecycle.archive("gone", "test")

      assert Enum.map(Curator.candidates(), & &1.name) == ["mine-a"]
    end
  end

  describe "the deterministic pass" do
    test "marks stale, archives, and reactivates on the activity clock", %{dir: dir} do
      agent_skill("fresh", 1)
      agent_skill("getting-old", 20)
      agent_skill("long-dead", 45)
      agent_skill("came-back", 0)
      person_skill(dir, "ancient-but-mine", 400)
      Stats.set_state("came-back", "stale")

      plan = Curator.plan() |> Map.new(&{&1.name, {&1.from, &1.to}})

      assert plan == %{
               "getting-old" => {"active", "stale"},
               "long-dead" => {"active", "archived"},
               "came-back" => {"stale", "active"}
             }
    end

    test "a skill never used is dated from when it was created, and any use resets the clock" do
      agent_skill("used-lately", 45)
      Stats.bump_use("used-lately")
      agent_skill("opened-lately", 45)
      Stats.bump_view("opened-lately")

      assert Curator.plan() == []
    end

    test "the thresholds are the settings" do
      agent_skill("ten-days", 10)
      assert Curator.plan() == []

      assert :ok = Settings.put("stale_after_days", "7")
      assert [%{name: "ten-days", to: "stale"}] = Curator.plan()
    end
  end

  describe "a run" do
    test "applies the transitions, archives recoverably, snapshots first, and leaves a report", %{dir: dir} do
      agent_skill("getting-old", 20)
      agent_skill("long-dead", 45)
      person_skill(dir, "hand-written", 400)

      assert {:ok, report} = Curator.run()

      assert state_of("getting-old") == "stale"
      assert state_of("long-dead") == "archived"
      refute File.exists?(Path.join(dir, "long-dead"))
      assert File.exists?(Path.join(dir, "getting-old"))
      assert File.exists?(Path.join(dir, "hand-written"))
      assert Ownership.origin("hand-written") == :user

      assert report["summary"] =~ "1 marked stale, 1 archived"
      assert is_binary(report["backup"])
      assert Enum.any?(Pepe.Skills.Backup.list(), &(&1.id == report["backup"]))
      assert File.read!(report["report"]) =~ "long-dead: active to archived"
      assert File.exists?(String.replace_suffix(report["report"], ".md", ".json"))

      assert %{"run_count" => 1, "last_report" => path} = State.load()
      assert path == report["report"]
      assert Enum.any?(Ledger.recent(20), &(&1.action == "curator_run"))

      # Nothing was deleted: a person can put it back.
      assert {:ok, _} = Lifecycle.restore("long-dead", "user:cli")
      assert File.exists?(Path.join(dir, "long-dead"))
    end

    test "a dry run changes nothing and takes no snapshot, but still reports" do
      agent_skill("long-dead", 45)

      assert {:ok, report} = Curator.run(dry_run: true)

      assert state_of("long-dead") == "active"
      assert report["dry_run"] == true
      assert report["backup"] == nil
      assert report["report"] =~ "-dry-run.md"
      assert File.read!(report["report"]) =~ "nothing was changed"
      assert State.load()["run_count"] == 0
      assert Pepe.Skills.Backup.list() == []
    end

    test "a run with nothing to do takes no snapshot" do
      agent_skill("fresh", 1)
      assert {:ok, %{"transitions" => [], "backup" => nil}} = Curator.run()
    end
  end

  describe "when it runs by itself" do
    test "not when disabled or paused" do
      :ok = Settings.put("enabled", false)
      assert {:skip, :disabled} = Curator.due()
      :ok = Settings.put("enabled", true)
      State.set_paused(true)
      assert {:skip, :paused} = Curator.due()
    end

    test "the first look only records the time and waits one interval" do
      assert {:skip, :seeded} = Curator.due()
      assert State.last_run_at()
      assert {:skip, :not_due} = Curator.due()
    end

    test "after the interval it waits for the conversations to go quiet, then runs" do
      now = DateTime.utc_now()
      State.update(%{"last_run_at" => DateTime.to_iso8601(DateTime.add(now, -8 * @day))})

      Repo.insert!(%Run{
        project: "default",
        at: System.system_time(:second) - 60,
        agent: "a",
        session: "s",
        source: "test",
        ms: 1,
        outcome: "ok"
      })

      assert {:skip, :busy} = Curator.due(now)

      Repo.delete_all(Run)

      Repo.insert!(%Run{
        project: "default",
        at: System.system_time(:second) - 3 * 3600,
        agent: "a",
        session: "s",
        source: "test",
        ms: 1,
        outcome: "ok"
      })

      assert :run = Curator.due(now)
    end

    test "maybe_run runs once due and records it" do
      State.update(%{"last_run_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -30 * @day))})
      agent_skill("long-dead", 45)

      assert {:ran, %{"transitions" => [%{"name" => "long-dead"}]}} = Curator.maybe_run()
      assert {:skip, :not_due} = Curator.maybe_run()
    end
  end

  describe "the settings" do
    test "defaults, casting, unknown keys, and stale never longer than archive" do
      assert %{"enabled" => true, "consolidate" => false, "stale_after_days" => 14, "archive_after_days" => 30} = Settings.all()

      assert :ok = Settings.put("interval_hours", "24")
      assert Settings.interval_hours() == 24
      assert :ok = Settings.put("consolidate", "on")
      assert Settings.consolidate?()

      assert {:error, msg} = Settings.put("nope", 1)
      assert msg =~ "unknown curator setting"
      assert {:error, _} = Settings.put("interval_hours", "soon")
      assert {:error, msg} = Settings.put("stale_after_days", 31)
      assert msg =~ "cannot be longer"
      assert {:error, msg} = Settings.put("archive_after_days", 5)
      assert msg =~ "cannot be shorter"
    end
  end

  describe "the model pass" do
    setup do
      Config.put_agent(%Agent{name: "worker", model: "mock", system_prompt: "hi", tools: ["bash"]})
      Config.set_default_agent("worker")
      :ok
    end

    test "is skipped with fewer than two skills it may change" do
      agent_skill("only-one", 1)
      assert %{"ran" => false, "summary" => summary} = Consolidate.run()
      assert summary =~ "nothing to merge"
    end

    test "merges through skill_manage: the umbrella is agent-owned, the absorbed skill archived, all under the curator actor" do
      agent_skill("notes-v1", 1)
      agent_skill("notes-v2", 1)

      umbrella = doc("release-notes", "Shared procedure for release notes.")

      script([
        [call("c1", "skill_manage", %{"action" => "create", "name" => "release-notes", "content" => umbrella})],
        [
          call("c2", "skill_manage", %{
            "action" => "write_file",
            "name" => "release-notes",
            "file_path" => "references/v1.md",
            "file_content" => "the v1 detail"
          })
        ],
        [call("c3", "skill_manage", %{"action" => "delete", "name" => "notes-v1", "absorbed_into" => "release-notes"})]
      ])

      assert {:ok, report} = Curator.run(consolidate: true)

      assert %{"ran" => true, "archived" => [%{"name" => "notes-v1", "into" => "release-notes"}]} = report["consolidation"]
      assert Ownership.origin("release-notes") == :agent
      assert Ownership.origin("notes-v1") == :missing
      assert File.read!(Path.join([Pepe.Skills.user_dir(), "release-notes", "references", "v1.md"])) == "the v1 detail"
      assert File.read!(report["report"]) =~ "archived notes-v1 into release-notes"
      assert Enum.any?(Ledger.recent(30, "release-notes"), &(&1.actor == "curator" and &1.action == "create"))
    end

    test "refuses to archive without naming where the content went" do
      agent_skill("notes-v1", 1)
      agent_skill("notes-v2", 1)
      script([[call("c1", "skill_manage", %{"action" => "delete", "name" => "notes-v1"})]])

      assert %{"archived" => []} = Consolidate.run()
      assert Ownership.origin("notes-v1") == :agent
    end

    test "cannot change a person's skill, however it is asked", %{dir: dir} do
      agent_skill("notes-v1", 1)
      agent_skill("notes-v2", 1)
      person_skill(dir, "mine", 1)
      script([[call("c1", "skill_manage", %{"action" => "delete", "name" => "mine", "absorbed_into" => "notes-v1"})]])

      Consolidate.run()
      assert File.exists?(Path.join(dir, "mine"))
    end

    test "a dry run holds no write tool, so it can only describe" do
      agent_skill("notes-v1", 1)
      agent_skill("notes-v2", 1)
      script([[call("c1", "skill_manage", %{"action" => "delete", "name" => "notes-v1", "absorbed_into" => "notes-v2"})]])

      assert {:ok, report} = Curator.run(dry_run: true, consolidate: true)

      assert report["consolidation"]["dry_run"] == true
      assert Ownership.origin("notes-v1") == :agent
      assert report["consolidation"]["model_summary"] == "merged them"

      tools =
        :curator_requests
        |> Elixir.Agent.get(& &1)
        |> Enum.flat_map(&(&1 |> Jason.decode!() |> Map.get("tools", [])))
        |> Enum.map(& &1["function"]["name"])
        |> Enum.uniq()

      assert "skill" in tools
      refute "skill_manage" in tools
    end

    test "the prompt lists only the skills it may change, with how much each was used", %{dir: dir} do
      agent_skill("notes-v1", 1)
      agent_skill("notes-v2", 1)
      person_skill(dir, "secret-of-a-person", 1)
      Stats.bump_use("notes-v1")

      prompt = Consolidate.prompt(Curator.candidates(), false)
      assert prompt =~ "- notes-v1 (used 1 times"
      assert prompt =~ "- notes-v2 (used 0 times"
      refute prompt =~ "secret-of-a-person"
      refute prompt =~ "DRY RUN"
      assert Consolidate.prompt(Curator.candidates(), true) =~ "DRY RUN"
    end
  end

  defp call(id, name, args), do: %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
end
