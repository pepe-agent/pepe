defmodule Pepe.Agent.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_ws_#{System.unique_integer([:positive])}")
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

  test "relative paths resolve into the agent workspace" do
    assert Workspace.resolve("people.md", "zak") == Path.join(Workspace.dir("zak"), "people.md")
  end

  test "shared/ paths resolve into the shared space" do
    assert Workspace.resolve("shared/people.md", "zak") ==
             Path.join(Workspace.shared_dir(), "people.md")
  end

  test "plugins/ and skills/ paths resolve into their global dirs" do
    assert Workspace.resolve("plugins/x.exs", "zak") ==
             Path.join(Workspace.plugins_dir(), "x.exs")

    assert Workspace.resolve("skills/x.md", "zak") == Path.join(Workspace.skills_dir(), "x.md")
  end

  test "absolute paths are left as-is" do
    assert Workspace.resolve("/etc/hosts", "zak") == "/etc/hosts"
  end

  test "resolve_in_ctx uses the bound agent, else cwd" do
    ctx = %{agent: %{name: "zak"}, cwd: "/tmp"}

    assert Workspace.resolve_in_ctx("notes.md", ctx) ==
             Path.join(Workspace.dir("zak"), "notes.md")

    assert Workspace.resolve_in_ctx("notes.md", %{cwd: "/tmp"}) == "/tmp/notes.md"
  end

  # Unique per test run so a real directory a developer or CI host happens to already
  # have at this path can never make "was never created" pass for the wrong reason.
  defp override_dir, do: Path.join(System.tmp_dir!(), "pepe_ws_override_#{System.unique_integer([:positive])}")

  test "resolve_in_ctx: cwd_override wins even with a bound agent" do
    override = override_dir()
    ctx = %{agent: %{name: "zak"}, cwd: "/tmp", cwd_override: override}

    assert Workspace.resolve_in_ctx("lib/foo.ex", ctx) == Path.join(override, "lib/foo.ex")
    assert Workspace.resolve_in_ctx("/etc/hosts", ctx) == "/etc/hosts"
  end

  test "resolve_in_ctx: a nil cwd_override falls back to the bound agent, not an error" do
    ctx = %{agent: %{name: "zak"}, cwd: "/tmp", cwd_override: nil}
    assert Workspace.resolve_in_ctx("notes.md", ctx) == Path.join(Workspace.dir("zak"), "notes.md")
  end

  test "cwd_in_ctx: cwd_override wins even with a bound agent, and is never created on disk" do
    override = override_dir()
    ctx = %{agent: %{name: "zak"}, cwd: "/tmp", cwd_override: override}
    assert Workspace.cwd_in_ctx(ctx) == override
    refute File.dir?(override)
  end

  test "an agent with no SOUL and the default seed gets onboarding guidance" do
    agent = %{name: "zak", system_prompt: Pepe.Config.Agent.default_prompt()}
    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "Pepe"
    assert prompt =~ "identity isn't set up yet"
    assert prompt =~ "offer to set one up"
  end

  test "every agent is told to use the documented way before declaring a blocker, and to fix a stale note" do
    prompt = Workspace.system_prompt(%{name: "zak", system_prompt: "You are Vega, a terse ops bot."})

    assert prompt =~ "The documented way beats what you remember"
    assert prompt =~ "source wins"
    assert prompt =~ "Fix what you find stale"
    assert prompt =~ "Never write the value of a secret"
  end

  describe "a prompt carries only the paragraphs that can matter" do
    @group "A shared channel can hold more than one person"
    @reactions "Reactions as feedback"
    @image "Sharing an image"
    @env "An env var you can't see"
    @parallel "Work in parallel"
    @advance "Advance with tools"

    defp prompt(tools, key \\ nil) do
      agent = %{name: "zak", system_prompt: "You are Vega, a terse ops bot.", tools: tools}
      Workspace.system_prompt(agent, key: key)
    end

    test "with no conversation key the prompt is the full one" do
      full = prompt(["bash", "send_file"])
      for part <- [@group, @reactions, @image, @env, @parallel, @advance], do: assert(full =~ part)
    end

    test "a one-person surface drops the group-chat and reactions paragraphs" do
      for key <- ["web:abc", "api:abc", "widget:abc", "acp:abc", "tui:abc"] do
        text = prompt(["bash", "send_file"], key)
        refute text =~ @group, key
        refute text =~ @reactions, key
        assert text =~ "Finish the job", key
      end
    end

    test "a chat app keeps the group paragraph, and reactions only where they arrive" do
      telegram = prompt(["bash", "send_file"], "telegram:123")
      assert telegram =~ @group
      assert telegram =~ @reactions

      discord = prompt(["bash", "send_file"], "discord:acme/bot:G1")
      assert discord =~ @group
      refute discord =~ @reactions

      assert prompt([], "slack:default/bot:C1") =~ @reactions
    end

    test "tool paragraphs go only for an agent with no tools at all" do
      bare = prompt([])
      for part <- [@advance, @parallel, "Persistence is for finding things", @env, @image], do: refute(bare =~ part, part)
      assert bare =~ "Finish the job"
      assert bare =~ "Trust tools over memory"

      assert prompt(["read_file"]) =~ @advance
    end

    test "the env var paragraph needs bash and the image paragraph needs send_file" do
      refute prompt(["read_file"]) =~ @env
      assert prompt(["bash"]) =~ @env
      refute prompt(["bash"]) =~ @image
      assert prompt(["send_file"]) =~ @image
    end

    test "an agent given without a tool list keeps every paragraph" do
      text = Workspace.system_prompt(%{name: "zak", system_prompt: "You are Vega."}, key: "telegram:1")
      for part <- [@group, @reactions, @image, @env, @parallel, @advance], do: assert(text =~ part)
    end

    test "the same agent costs less where less applies" do
      tokens = fn text -> div(String.length(text), 4) end
      assert tokens.(prompt(["bash", "send_file"], "web:x")) < tokens.(prompt(["bash", "send_file"]))
      assert tokens.(prompt([], "api:x")) < tokens.(prompt(["bash", "send_file"], "web:x"))
    end
  end

  describe "the size of what every agent inherits" do
    # A ceiling, not a target: the contract grows when a real case earns a paragraph, and this test is
    # where that growth has to be noticed and decided on. Raise it on purpose, with the reason.
    @contract_ceiling_tokens 2_100

    test "the behavior contract stays under its ceiling" do
      {_, contract} = Enum.find(Workspace.system_prompt_sections(%{name: "zak", system_prompt: "x"}), &match?({"behavior contract", _}, &1))
      assert div(String.length(contract), 4) <= @contract_ceiling_tokens
    end
  end

  test "a user-provided seed persona is kept (no onboarding override)" do
    agent = %{name: "zak", system_prompt: "You are Vega, a terse ops bot."}
    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "You are Vega, a terse ops bot."
    refute prompt =~ "identity isn't set up yet"
  end

  test "system_prompt uses SOUL.md when present, else the seed prompt" do
    agent = %{name: "zak", system_prompt: "seed persona"}
    assert Workspace.system_prompt(agent) =~ "seed persona"

    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "SOUL.md"), "You are ZakAI.")

    prompt = Workspace.system_prompt(agent)
    assert prompt =~ "You are ZakAI."
    refute prompt =~ "seed persona"
  end

  test "manage_agent's rename action renames the agent in config and moves its workspace" do
    Pepe.Config.put_agent(%Pepe.Config.Agent{name: "teste", system_prompt: "x", tools: []})
    File.mkdir_p!(Workspace.dir("teste"))
    File.write!(Path.join(Workspace.dir("teste"), "SOUL.md"), "soul")

    assert {:ok, _} =
             Pepe.Tools.ManageAgent.run(
               %{"action" => "rename", "target" => "teste", "value" => "zak"},
               %{agent: %Pepe.Config.Agent{name: "teste"}}
             )

    assert Pepe.Config.get_agent("teste") == nil
    assert Pepe.Config.get_agent("zak")
    assert File.read!(Path.join(Workspace.dir("zak"), "SOUL.md")) == "soul"
  end

  test "rename moves the agent workspace directory" do
    File.mkdir_p!(Workspace.dir("teste"))
    File.write!(Path.join(Workspace.dir("teste"), "SOUL.md"), "I am.")

    Workspace.rename("teste", "zak")

    refute File.dir?(Workspace.dir("teste"))
    assert File.read!(Path.join(Workspace.dir("zak"), "SOUL.md")) == "I am."
  end

  test "system_prompt lists knowledge files by name (not content) and adds the note" do
    agent = %{name: "zak", system_prompt: "seed"}
    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "clients.md"), "The Acme account renews in May.")
    File.write!(Path.join(Workspace.dir("zak"), "people.md"), "lots of people data")

    prompt = Workspace.system_prompt(agent)

    # listed by name, read on demand - content NOT preloaded
    assert prompt =~ "- clients.md"
    assert prompt =~ "- people.md"
    refute prompt =~ "The Acme account renews in May."
    refute prompt =~ "lots of people data"

    assert prompt =~ "Your workspace"
    assert prompt =~ "shared/"
  end

  test "system_prompt lists scripts the agent wrote earlier, by name, newest first, skipping shared/" do
    agent = %{name: "zak", system_prompt: "seed"}
    dir = Workspace.dir("zak")
    File.mkdir_p!(Path.join(dir, "scripts"))
    File.mkdir_p!(Path.join(dir, "shared"))
    File.write!(Path.join(dir, "scripts/leads_report.sql"), "select 1")
    File.write!(Path.join(dir, "export.py"), "print(1)")
    File.write!(Path.join(dir, "shared/other.sh"), "echo")
    File.write!(Path.join(dir, "notes.txt"), "not a script")

    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "Scripts you wrote earlier"
    assert prompt =~ "- scripts/leads_report.sql"
    assert prompt =~ "- export.py"
    refute prompt =~ "other.sh"
    refute prompt =~ "notes.txt"
    refute prompt =~ "select 1"
  end

  test "an agent with no scripts gets no scripts section" do
    refute Workspace.system_prompt(%{name: "zak", system_prompt: "seed"}) =~ "Scripts you wrote earlier"
  end

  describe "the notes every conversation starts with" do
    setup do
      dir = Workspace.dir("zak")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "TOOLS.md"), "Instagram posts: use the image tool, style ref posts/ref.png.")
      File.write!(Path.join(dir, "MEMORY.md"), "The user prefers short answers.")
      File.write!(Path.join(dir, "USER.md"), "The user is Jho.")
      {:ok, agent: %{name: "zak", system_prompt: "seed"}}
    end

    test "a private chat starts with TOOLS.md, MEMORY.md and USER.md already in context", %{agent: agent} do
      for key <- ["telegram:12345", "telegram:bot2:12345", "telegram:12345#t7", "web:abc", "api:x"] do
        prompt = Workspace.system_prompt(agent, key: key)
        assert prompt =~ "style ref posts/ref.png", key
        assert prompt =~ "prefers short answers", key
        assert prompt =~ "The user is Jho.", key
      end

      refute Workspace.system_prompt(agent, key: "web:abc") =~ "- MEMORY.md"
    end

    test "a group or an unknown chat app gets TOOLS.md but never the personal notes", %{agent: agent} do
      for key <- ["telegram:-100123", "telegram:bot2:-100123#t4", "slack:C1", "discord:9", "whatsapp:55"] do
        prompt = Workspace.system_prompt(agent, key: key)
        assert prompt =~ "style ref posts/ref.png", key
        refute prompt =~ "prefers short answers", key
        refute prompt =~ "The user is Jho.", key
        assert prompt =~ "- MEMORY.md", key
      end
    end

    test "a conversation that may not learn (a widget visitor, a client on a customer bot) never gets the personal notes", %{agent: agent} do
      for key <- ["widget:example.com:abc", "telegram:12345", "api:x", "web:abc"] do
        prompt = Workspace.system_prompt(agent, key: key, learn: false)
        refute prompt =~ "prefers short answers", key
        refute prompt =~ "The user is Jho.", key
        refute prompt =~ "Write it down as you go", key
        refute prompt =~ "## Reactions as feedback", key
        assert prompt =~ "style ref posts/ref.png", key
      end
    end

    test "the instruction to write things down goes only to a learning conversation of an agent that can write", %{agent: agent} do
      assert Workspace.system_prompt(agent, key: "web:abc", learn: true) =~ "Write it down as you go"
      assert Workspace.system_prompt(agent) =~ "Write it down as you go"

      refute Workspace.system_prompt(%{agent | system_prompt: "seed"} |> Map.put(:tools, ["read_file"]), key: "web:abc") =~
               "Write it down as you go"

      refute Workspace.system_prompt(Map.put(agent, :tools, []), key: "web:abc") =~ "Write it down as you go"
    end

    test "today's and yesterday's daily log open a private conversation; older days and groups do not", %{agent: agent} do
      dir = Workspace.dir("zak")
      File.mkdir_p!(Path.join(dir, "memory"))
      {:ok, now} = DateTime.now(Pepe.Config.default_timezone())
      today = DateTime.to_date(now)

      File.write!(Path.join(dir, Workspace.daily_path(today)), "Sent the weekly report to finance.")
      File.write!(Path.join(dir, Workspace.daily_path(Date.add(today, -1))), "Migration still open.")
      File.write!(Path.join(dir, Workspace.daily_path(Date.add(today, -5))), "An old day.")

      private = Workspace.system_prompt(agent, key: "web:abc")
      assert private =~ "Sent the weekly report to finance."
      assert private =~ "Migration still open."
      refute private =~ "An old day."

      for opts <- [[key: "telegram:-100123"], [key: "web:abc", learn: false], [key: "widget:x:1", learn: false]] do
        refute Workspace.system_prompt(agent, opts) =~ "Sent the weekly report to finance.", inspect(opts)
      end
    end

    test "a notes file that grows is clipped, and says so", %{agent: agent} do
      File.write!(Path.join(Workspace.dir("zak"), "TOOLS.md"), String.duplicate("recipe line\n", 5_000))
      prompt = Workspace.system_prompt(agent, key: "web:abc")

      assert prompt =~ "clipped to keep every conversation light"
      assert String.length(prompt) < 60_000
    end
  end

  describe "langfuse_prompt" do
    setup do
      {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLangfuse, port: 0, scheme: :http)
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      prev = for k <- ~w(LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASE_URL), do: {k, System.get_env(k)}

      on_exit(fn ->
        Process.exit(server, :normal)

        Enum.each(prev, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
      System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
      System.put_env("LANGFUSE_BASE_URL", "http://localhost:#{port}")
      :ok
    end

    test "overrides both the seed and SOUL.md when set and reachable" do
      name = "wp-#{System.unique_integer([:positive])}"
      agent = %{name: "zak", system_prompt: "local seed", langfuse_prompt: name}
      File.mkdir_p!(Workspace.dir("zak"))
      File.write!(Path.join(Workspace.dir("zak"), "SOUL.md"), "local SOUL.md persona")

      prompt = Workspace.system_prompt(agent)

      assert prompt =~ "persona for #{name}"
      refute prompt =~ "local seed"
      refute prompt =~ "local SOUL.md persona"
    end

    test "falls back to the local resolution when Langfuse is unreachable" do
      System.put_env("LANGFUSE_BASE_URL", "http://127.0.0.1:1")
      agent = %{name: "zak", system_prompt: "local seed", langfuse_prompt: "whatever"}

      assert Workspace.system_prompt(agent) =~ "local seed"
    end

    test "falls back to the local resolution when the prompt doesn't exist in Langfuse" do
      agent = %{name: "zak", system_prompt: "local seed", langfuse_prompt: "missing-#{System.unique_integer([:positive])}"}

      assert Workspace.system_prompt(agent) =~ "local seed"
    end

    test "is a no-op when unset (nil), same as before this feature existed" do
      agent = %{name: "zak", system_prompt: "local seed", langfuse_prompt: nil}
      assert Workspace.system_prompt(agent) =~ "local seed"
    end
  end

  test "system_prompt teaches the reaction-as-feedback convention" do
    agent = %{name: "zak", system_prompt: "seed"}
    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "[reacted <emoji>]"
    assert prompt =~ "append a short note to TOOLS.md"
    assert prompt =~ "never answer it"
  end

  describe "capability_nudge" do
    test "off by default: no mention of it in the prompt, same as before this flag existed" do
      agent = %{name: "zak", system_prompt: "seed"}
      refute Workspace.system_prompt(agent) =~ "Mentioning what else you can do"
    end

    test "explicitly off behaves the same as absent" do
      agent = %{name: "zak", system_prompt: "seed", capability_nudge: false}
      refute Workspace.system_prompt(agent) =~ "Mentioning what else you can do"
    end

    test "on: teaches the agent it may nudge toward a related capability" do
      agent = %{name: "zak", system_prompt: "seed", capability_nudge: true}
      prompt = Workspace.system_prompt(agent)

      assert prompt =~ "Mentioning what else you can do"
      assert prompt =~ "Watches"
      assert prompt =~ "Not every turn, not a menu"
    end
  end

  describe "topic_reroute" do
    test "off by default: nothing about changing subject in the prompt" do
      refute Workspace.system_prompt(%{name: "zak", system_prompt: "seed"}) =~ "When the subject changes"
      refute Workspace.system_prompt(%{name: "zak", system_prompt: "seed", topic_reroute: false}) =~ "When the subject changes"
    end

    test "on: teaches the agent to ask before moving anyone, and names no other agent" do
      prompt = Workspace.system_prompt(%{name: "zak", system_prompt: "seed", topic_reroute: true})

      assert prompt =~ "When the subject changes"
      assert prompt =~ "hand_back"
      assert prompt =~ "nothing changes unless they say yes"
    end
  end

  test "IDENTITY.md is small enough to stay always-loaded" do
    agent = %{name: "zak", system_prompt: "seed"}
    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "IDENTITY.md"), "name: ZakAI")

    assert Workspace.system_prompt(agent) =~ "name: ZakAI"
  end

  test "BOOT.md is loaded fresh into every new session, not just listed by name" do
    agent = %{name: "zak", system_prompt: "seed"}
    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "BOOT.md"), "Follow up with Jho about the invoice.")

    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "Follow up with Jho about the invoice."
    refute prompt =~ "- BOOT.md"
  end
end
