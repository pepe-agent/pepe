defmodule Pepe.CLITest do
  @moduledoc """
  The `mix pepe` CLI: the commands that define the setup (models, agents,
  companies) plus the ones that only report on it (config, tools, doctor, help).

  Every test asserts on both halves of what the command promises: the output the
  user reads, and the effect it left behind in `Pepe.Config`.
  """
  use Pepe.CLICase, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent

  defp add_model(name \\ "openai") do
    run(["model", "add", name, "--base-url", "https://api.example.com/v1", "--api-key", "sk-test", "--model", "gpt-4o"])
  end

  describe "help and unknown commands" do
    test "with no arguments it prints the command reference" do
      {out, _err} = run([])

      assert out =~ "mix pepe model add"
      assert out =~ "mix pepe agent add"
      assert out =~ "mix pepe run"
    end

    test "an unknown command names it, then shows the help instead of failing silently" do
      {out, err} = run(["frobnicate", "--now"])

      assert err =~ "unknown command: frobnicate --now"
      assert out =~ "mix pepe agent add"
    end

    test "`help GROUP` and `GROUP help` reach the same page" do
      {via_help, _} = run(["help", "agent"])
      {via_group, _} = run(["agent", "help"])

      assert via_help =~ "mix pepe agent - manage agents"
      assert via_help == via_group
    end

    test "version answers with no config and no model connection" do
      {out, _err} = run(["version"])

      assert out =~ "pepe #{Pepe.Update.current()}"
    end
  end

  describe "config" do
    test "reports the config path and what is set" do
      add_model()
      run(["agent", "add", "support", "--prompt", "you help"])

      {out, _err} = run(["config"])

      assert out =~ Config.path()
      assert out =~ "default model: openai"
      assert out =~ "default agent: support"
      assert out =~ "agents: support"
    end

    test "on a fresh install it says nothing is set instead of crashing" do
      {out, _err} = run(["config"])

      assert out =~ "default model: (none)"
      assert out =~ "default agent: (none)"
    end
  end

  describe "tools" do
    test "lists every built-in tool with its description" do
      {out, _err} = run(["tools"])

      for name <- Pepe.Tools.names(), do: assert(out =~ name)
      assert out =~ "bash"
      # The description is the point of the listing: a bare name list would not tell
      # anyone which tool to grant.
      assert out =~ ~r/bash - \w+/
    end
  end

  describe "doctor --offline" do
    test "reports a healthy setup when every reference resolves" do
      add_model()
      run(["agent", "add", "support", "--prompt", "you help", "--model", "openai"])
      Config.load() |> Map.delete("telegram") |> Config.save()

      {out, _err} = run(["doctor", "--offline"])

      assert out =~ "(offline)"
      assert out =~ "healthy"
    end

    test "flags an agent pointing at a model connection that does not exist" do
      Config.put_agent(%Agent{name: "support", model: "ghost-model", tools: []})

      {out, err} = run(["doctor", "--offline"])

      assert err =~ "ghost-model" or out =~ "ghost-model"
      assert err =~ "issues found"
    end

    test "flags a ${ENV_VAR} secret that is not exported" do
      run([
        "model",
        "add",
        "openai",
        "--base-url",
        "https://api.example.com/v1",
        "--api-key",
        "${PEPE_TEST_MISSING_KEY}",
        "--model",
        "gpt-4o"
      ])

      {out, err} = run(["doctor", "--offline"])

      assert out =~ "PEPE_TEST_MISSING_KEY" or err =~ "PEPE_TEST_MISSING_KEY"
      assert err =~ "issues found"
    end
  end

  describe "model add" do
    test "saves the connection and can make it the default" do
      {out, _err} =
        run([
          "model",
          "add",
          "openai",
          "--base-url",
          "https://api.example.com/v1",
          "--api-key",
          "sk-test",
          "--model",
          "gpt-4o",
          "--default"
        ])

      assert out =~ "model connection openai saved"

      model = Config.get_model("openai")
      assert model.base_url == "https://api.example.com/v1"
      assert model.api_key == "sk-test"
      assert model.model == "gpt-4o"
      assert Config.default_model_name() == "openai"
    end

    test "a taken name is auto-renamed, never silently overwritten" do
      run(["model", "add", "openai", "--base-url", "https://a.example.com/v1", "--model", "first"])

      {out, _err} = run(["model", "add", "openai", "--base-url", "https://b.example.com/v1", "--model", "second"])

      assert out =~ "already exists"
      assert out =~ "openai-2"
      assert Config.get_model("openai").model == "first"
      assert Config.get_model("openai-2").model == "second"
    end

    test "refuses a name that is not a legal handle" do
      {_out, err} = run(["model", "add", "acme/openai", "--base-url", "https://api.example.com/v1", "--model", "gpt-4o"])

      assert err =~ "invalid name"
      assert Config.models() == []
    end

    test "refuses a company that does not exist" do
      {_out, err} =
        run(["model", "add", "openai", "--company", "ghost", "--base-url", "https://api.example.com/v1", "--model", "gpt-4o"])

      assert err =~ "unknown company: ghost"
      assert Config.models() == []
    end
  end

  describe "model list / default / remove / rename" do
    test "lists saved connections and marks the default" do
      add_model("openai")
      add_model("openrouter")
      run(["model", "default", "openrouter"])

      {out, _err} = run(["model", "list"])

      assert out =~ "openai"
      assert out =~ "openrouter"
      assert out =~ ~r/openrouter \(default\)/
      assert out =~ "url:   https://api.example.com/v1"
    end

    test "with no connections it tells you how to add one" do
      {out, _err} = run(["model", "list"])

      assert out =~ "no model connections"
      assert out =~ "mix pepe model add"
    end

    test "default switches which connection agents resolve to" do
      add_model("openai")
      add_model("openrouter")

      {out, _err} = run(["model", "default", "openrouter"])

      assert out =~ "default model -> openrouter"
      assert Config.default_model_name() == "openrouter"
    end

    test "remove drops it from the config" do
      add_model("openai")

      {out, _err} = run(["model", "remove", "openai"])

      assert out =~ "removed model connection openai"
      assert Config.get_model("openai") == nil
    end

    test "rename keeps every reference resolving" do
      add_model("openai")
      run(["agent", "add", "support", "--model", "openai", "--prompt", "you help"])

      {out, _err} = run(["model", "rename", "openai", "primary"])

      assert out =~ "openai -> primary"
      assert Config.get_model("primary").model == "gpt-4o"
      assert Config.model_for_agent(Config.get_agent("support")).name == "primary"
    end

    test "renaming a connection that does not exist says so" do
      {_out, err} = run(["model", "rename", "ghost", "primary"])

      assert err =~ "unknown model connection: ghost"
    end

    test "a subcommand with a missing argument prints the usage line" do
      {_out, err} = run(["model", "default"])

      assert err =~ "usage: mix pepe model"
    end
  end

  describe "agent add" do
    test "saves the agent with the tools it was granted" do
      {out, _err} = run(["agent", "add", "support", "--prompt", "you answer tickets", "--tools", "bash,read_file"])

      assert out =~ "agent support saved"
      assert out =~ "tools: bash, read_file"

      agent = Config.get_agent("support")
      assert agent.system_prompt == "you answer tickets"
      assert agent.tools == ["bash", "read_file"]
      assert agent.max_iterations == 12
    end

    test "omitting --tools grants every tool" do
      run(["agent", "add", "support", "--prompt", "you help"])

      assert Config.get_agent("support").tools == Pepe.Tools.names()
    end

    test "--admin makes it a super-admin over every agent" do
      run(["agent", "add", "boss", "--prompt", "you run things", "--admin"])

      assert Config.get_agent("boss").can_manage == ["*"]
    end

    test "--default makes it the agent every surface answers with" do
      run(["agent", "add", "support", "--prompt", "you help", "--default"])

      assert Config.default_agent_name() == "support"
    end

    test "--company scopes the handle into that company" do
      run(["company", "add", "acme"])

      {out, _err} = run(["agent", "add", "support", "--company", "acme", "--prompt", "you help"])

      assert out =~ "agent acme/support saved"
      assert Config.get_agent("acme/support")
      assert Config.get_agent("support") == nil
    end

    test "refuses a company that does not exist, and saves nothing" do
      {_out, err} = run(["agent", "add", "support", "--company", "ghost", "--prompt", "you help"])

      assert err =~ "unknown company: ghost"
      assert Config.agents() == []
    end

    test "refuses a name carrying a company separator" do
      {_out, err} = run(["agent", "add", "acme/support", "--prompt", "you help"])

      assert err =~ "invalid name"
      assert Config.agents() == []
    end
  end

  describe "agent list / remove / default / rename" do
    test "lists agents, marking the default and its routes" do
      run(["agent", "add", "support", "--prompt", "a", "--tools", "read_file", "--default"])
      run(["agent", "add", "sales", "--prompt", "b", "--tools", "bash"])
      run(["agent", "route", "support", "sales"])

      {out, _err} = run(["agent", "list"])

      assert out =~ ~r/support \(default\)/
      assert out =~ "tools: read_file"
      assert out =~ "-> sales"
    end

    test "with no agents it tells you how to add one" do
      {out, _err} = run(["agent", "list"])

      assert out =~ "no agents"
      assert out =~ "mix pepe agent add"
    end

    test "a company's agents are hidden from the root listing and shown by --company" do
      run(["company", "add", "acme"])
      run(["agent", "add", "support", "--company", "acme", "--prompt", "a"])
      run(["agent", "add", "root-bot", "--prompt", "b"])

      {root, _} = run(["agent", "list"])
      {scoped, _} = run(["agent", "list", "--company", "acme"])
      {all, _} = run(["agent", "list", "--all"])

      assert root =~ "root-bot"
      refute root =~ "acme/support"
      assert scoped =~ "acme/support"
      refute scoped =~ "root-bot"
      assert all =~ "acme/support"
      assert all =~ "root-bot"
    end

    test "remove drops the agent from the config" do
      run(["agent", "add", "support", "--prompt", "a"])

      {out, _err} = run(["agent", "remove", "support"])

      assert out =~ "removed agent support"
      assert Config.get_agent("support") == nil
    end

    test "default sets the agent every surface answers with" do
      run(["agent", "add", "support", "--prompt", "a"])
      run(["agent", "add", "sales", "--prompt", "b"])

      {out, _err} = run(["agent", "default", "sales"])

      assert out =~ "default agent -> sales"
      assert Config.default_agent_name() == "sales"
    end

    test "rename moves the agent and its workspace" do
      run(["agent", "add", "support", "--prompt", "a"])
      workspace = Pepe.Agent.Workspace.dir("support")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "note.md"), "remembered")

      {out, _err} = run(["agent", "rename", "support", "helpdesk"])

      assert out =~ "support -> helpdesk"
      assert Config.get_agent("helpdesk")
      assert Config.get_agent("support") == nil
      assert File.read!(Path.join(Pepe.Agent.Workspace.dir("helpdesk"), "note.md")) == "remembered"
    end

    test "renaming an agent that does not exist says so" do
      {_out, err} = run(["agent", "rename", "ghost", "helpdesk"])

      assert err =~ "unknown agent: ghost"
      assert Config.get_agent("helpdesk") == nil
    end

    test "an unknown subcommand points at the help" do
      {_out, err} = run(["agent", "frobnicate"])

      assert err =~ "unknown: mix pepe agent frobnicate"
      assert err =~ "mix pepe agent help"
    end
  end

  describe "agent route / manage" do
    test "route lets one agent message another, and --remove takes it back" do
      run(["agent", "add", "support", "--prompt", "a"])
      run(["agent", "add", "sales", "--prompt", "b"])

      {out, _err} = run(["agent", "route", "support", "sales"])
      assert out =~ "support -> sales (can message)"
      assert Config.get_agent("support").can_message == ["sales"]

      {out, _err} = run(["agent", "route", "support", "sales", "--remove"])
      assert out =~ "removed route support -> sales"
      assert Config.get_agent("support").can_message == []
    end

    test "route refuses an agent that does not exist" do
      run(["agent", "add", "support", "--prompt", "a"])

      {_out, err} = run(["agent", "route", "support", "ghost"])

      assert err =~ "unknown agent: ghost"
      assert Config.get_agent("support").can_message == []
    end

    test "route refuses to cross a company boundary" do
      run(["company", "add", "acme"])
      run(["agent", "add", "support", "--prompt", "a"])
      run(["agent", "add", "inside", "--company", "acme", "--prompt", "b"])

      {_out, err} = run(["agent", "route", "support", "acme/inside"])

      assert err =~ "refusing route across companies"
      assert Config.get_agent("support").can_message == []
    end

    test "route with a missing target prints the usage line" do
      {_out, err} = run(["agent", "route", "support"])

      assert err =~ "usage: mix pepe agent route FROM TO"
    end

    test "manage grants administration over one agent or over all of them" do
      run(["agent", "add", "boss", "--prompt", "a"])
      run(["agent", "add", "support", "--prompt", "b"])

      {out, _err} = run(["agent", "manage", "boss", "support"])
      assert out =~ "boss can now manage support"
      assert Config.get_agent("boss").can_manage == ["support"]

      run(["agent", "manage", "boss", "*"])
      assert "*" in Config.get_agent("boss").can_manage
    end

    test "manage refuses an unknown target and suggests the wildcard" do
      run(["agent", "add", "boss", "--prompt", "a"])

      {_out, err} = run(["agent", "manage", "boss", "ghost"])

      assert err =~ "unknown agent: ghost"
      assert err =~ ~s(use "*" for all)
    end
  end

  describe "company" do
    test "add creates an isolated tenant" do
      {out, _err} = run(["company", "add", "acme", "--description", "the acme corp"])

      assert out =~ "company acme created"
      assert Config.company_exists?("acme")
      assert Config.get_company("acme")["description"] == "the acme corp"
    end

    test "add refuses a duplicate" do
      run(["company", "add", "acme"])

      {_out, err} = run(["company", "add", "acme"])

      assert err =~ "company acme already exists"
    end

    test "add refuses an illegal name" do
      {_out, err} = run(["company", "add", "acme corp!"])

      assert err =~ "invalid company name"
      assert Config.companies() == []
    end

    test "list shows each company and how many agents it holds" do
      run(["company", "add", "acme"])
      run(["agent", "add", "support", "--company", "acme", "--prompt", "a"])

      {out, _err} = run(["company", "list"])

      assert out =~ "acme (1 agent)"
    end

    test "with no companies it explains the root scope" do
      {out, _err} = run(["company", "list"])

      assert out =~ "no companies"
      assert out =~ "root scope"
    end

    test "remove refuses to orphan agents unless --force is given" do
      run(["company", "add", "acme"])
      run(["agent", "add", "support", "--company", "acme", "--prompt", "a"])

      {_out, err} = run(["company", "remove", "acme"])
      assert err =~ "still has 1 agent"
      assert Config.company_exists?("acme")

      {out, _err} = run(["company", "remove", "acme", "--force"])
      assert out =~ "removed company acme"
      refute Config.company_exists?("acme")
      assert Config.get_agent("acme/support") == nil
    end

    test "remove says so when the company does not exist" do
      {_out, err} = run(["company", "remove", "ghost"])

      assert err =~ "unknown company: ghost"
    end

    test "an unknown subcommand points at the help" do
      {_out, err} = run(["company", "frobnicate"])

      assert err =~ "unknown company command: frobnicate"
    end
  end

  # These four reported success for a name that was never there, and `default` went further
  # and wrote it: the install then looked configured and answered nothing, and only
  # `doctor` ever said why. Every sibling command (company remove, cron remove, watch
  # cancel, token revoke) validates. These now do too.
  describe "a name that does not exist" do
    test "model remove says so instead of claiming success" do
      {out, err} = run(["model", "remove", "ghost"])

      assert err =~ "unknown model connection: ghost"
      refute out =~ "removed"
    end

    test "model default refuses, rather than pointing the install at nothing" do
      {out, err} = run(["model", "default", "ghost"])

      assert err =~ "unknown model connection: ghost"
      refute out =~ "default model"
      refute Pepe.Config.default_model()
    end

    test "agent remove says so instead of claiming success" do
      {out, err} = run(["agent", "remove", "ghost"])

      assert err =~ "unknown agent: ghost"
      refute out =~ "removed"
    end

    test "agent default refuses" do
      {_out, err} = run(["agent", "default", "ghost"])

      assert err =~ "unknown agent: ghost"
      refute Pepe.Config.default_agent_name()
    end
  end
end
