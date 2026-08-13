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

  test "an agent with no SOUL and the default seed gets onboarding guidance" do
    agent = %{name: "zak", system_prompt: Pepe.Config.Agent.default_prompt()}
    prompt = Workspace.system_prompt(agent)

    assert prompt =~ "Pepe"
    assert prompt =~ "identity isn't set up yet"
    assert prompt =~ "offer to set one up"
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

  test "the rename_agent tool renames the agent in config and moves its workspace" do
    Pepe.Config.put_agent(%Pepe.Config.Agent{name: "teste", system_prompt: "x", tools: []})
    File.mkdir_p!(Workspace.dir("teste"))
    File.write!(Path.join(Workspace.dir("teste"), "SOUL.md"), "soul")

    assert {:ok, _} =
             Pepe.Tools.RenameAgent.run(%{"new_name" => "zak"}, %{agent: %{name: "teste"}})

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
    File.write!(Path.join(Workspace.dir("zak"), "USER.md"), "The user is Jho.")
    File.write!(Path.join(Workspace.dir("zak"), "people.md"), "lots of people data")

    prompt = Workspace.system_prompt(agent)

    # listed by name, read on demand - content NOT preloaded
    assert prompt =~ "- USER.md"
    assert prompt =~ "- people.md"
    refute prompt =~ "The user is Jho."
    refute prompt =~ "lots of people data"

    assert prompt =~ "Your workspace"
    assert prompt =~ "shared/"
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
    assert prompt =~ "append a short note to MEMORY.md"
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
