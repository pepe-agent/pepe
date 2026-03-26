defmodule Pepe.MigrateTest do
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_migtarget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    src = Path.join(System.tmp_dir!(), "pepe_migsrc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      File.rm_rf(src)
    end)

    %{src: src}
  end

  describe "openclaw" do
    defp write_openclaw(src) do
      File.write!(Path.join(src, "openclaw.json"), """
      {
        // a comment JSON5-style
        "models": { "providers": {
          "openai": { "baseUrl": "https://api.openai.com/v1",
            "apiKey": { "source": "env", "provider": "default", "id": "OPENAI_API_KEY" },
            "models": [{ "id": "gpt-4o", "name": "GPT-4o", "contextWindow": 128000 }] } } },
        "agents": { "list": [
          { "id": "assistant", "default": true, "model": { "primary": "openai/gpt-4o" },
            "tools": ["web_search", "bash", "some_unknown_tool"],
            "params": { "temperature": 0.7 } } ] },
        "channels": {
          "telegram": { "enabled": true, "botToken": "123:ABC", "allowFrom": ["42"] },
          "slack": { "enabled": true, "botToken": "xoxb-1", "signingSecret": "sss" },
          "discord": { "enabled": true, "token": "d-gateway" }
        }
      }
      """)

      File.mkdir_p!(Path.join([src, "workspace", "skills", "greeter"]))
      File.write!(Path.join([src, "workspace", "skills", "greeter", "SKILL.md"]), "use when greeting")
      File.write!(Path.join([src, "workspace", "AGENTS.md"]), "You are a helpful migrated agent.")
    end

    test "imports models, agents, persona and telegram", %{src: src} do
      write_openclaw(src)

      assert {:ok, report} = Pepe.Migrate.run("openclaw", from: src)

      model = Config.get_model("openai/gpt-4o")
      assert model.base_url == "https://api.openai.com/v1"
      assert model.api_key == "${OPENAI_API_KEY}"
      assert model.model == "gpt-4o"

      agent = Config.get_agent("assistant")
      assert agent.model == "openai/gpt-4o"
      assert agent.system_prompt == "You are a helpful migrated agent."
      assert agent.temperature == 0.7
      # tools mapped to the ones that exist in Pepe; unknown dropped
      assert Enum.sort(agent.tools) == ["bash", "web_search"]

      assert Config.telegram()["bot_token"] == "123:ABC"
      assert Config.telegram()["allowed_chats"] == ["42"]

      # slack -> a webhook connection; discord (gateway token) is reported, not mapped
      slack = Config.get_webhook("slack")
      assert slack["provider"] == "slack"
      assert slack["config"] == %{"bot_token" => "xoxb-1", "signing_secret" => "sss"}
      assert Enum.any?(report.skipped, &(&1.what == "channel discord"))

      # a skill came over
      assert File.read!(Path.join(Pepe.Agent.Workspace.skills_dir(), "greeter.md")) == "use when greeting"
      assert Enum.any?(report.applied, &(&1.kind == "skill"))
      assert Enum.any?(report.applied, &(&1.kind == "model"))
    end

    test "dry-run writes nothing", %{src: src} do
      write_openclaw(src)

      assert {:ok, report} = Pepe.Migrate.run("openclaw", from: src, dry_run: true)
      assert report.dry_run
      assert Config.get_model("openai/gpt-4o") == nil
      assert Config.get_agent("assistant") == nil
    end
  end

  describe "hermes" do
    test "imports the global model, the SOUL persona and a telegram token", %{src: src} do
      File.write!(Path.join(src, "config.yaml"), """
      model:
        default: "anthropic/claude"
        provider: "anthropic"
        base_url: "https://api.anthropic.com/v1"
      agent:
        personalities:
          coder: "You write code."
      platforms:
        whatsapp:
          enabled: true
          extra:
            phone_number_id: "111"
            access_token: "wa-token"
      """)

      File.write!(
        Path.join(src, ".env"),
        "ANTHROPIC_API_KEY=sk-xxx\nTELEGRAM_BOT_TOKEN=987:XYZ\nSLACK_BOT_TOKEN=xoxb-h\nTEAMS_CLIENT_ID=cid\nTEAMS_CLIENT_SECRET=csec\nTEAMS_TENANT_ID=tid\n"
      )

      File.write!(Path.join(src, "SOUL.md"), "You are the main hermes persona.")
      File.mkdir_p!(Path.join([src, "skills", "translate"]))
      File.write!(Path.join([src, "skills", "translate", "SKILL.md"]), "use when translating")
      File.mkdir_p!(Path.join([src, "profiles", "sales"]))
      File.write!(Path.join([src, "profiles", "sales", "SOUL.md"]), "You sell things.")

      assert {:ok, _report} = Pepe.Migrate.run("hermes", from: src)

      model = Config.get_model("anthropic")
      assert model.model == "anthropic/claude"
      assert model.api_key == "${ANTHROPIC_API_KEY}"

      assert Config.get_agent("assistant").system_prompt == "You are the main hermes persona."
      assert Config.get_agent("coder").system_prompt == "You write code."
      assert Config.get_agent("sales").system_prompt == "You sell things."
      assert Config.telegram()["bot_token"] == "987:XYZ"

      # whatsapp platform -> a webhook connection
      wa = Config.get_webhook("whatsapp")
      assert wa["provider"] == "whatsapp"
      assert wa["config"]["access_token"] == "wa-token"

      # slack and teams from .env -> webhook connections
      assert Config.get_webhook("slack")["config"]["bot_token"] == "xoxb-h"
      teams = Config.get_webhook("msteams")
      assert teams["config"] == %{"app_id" => "cid", "app_password" => "csec", "tenant_id" => "tid"}

      # a skill came over
      assert File.read!(Path.join(Pepe.Agent.Workspace.skills_dir(), "translate.md")) == "use when translating"
    end
  end

  test "unknown source and missing home error clearly", %{src: src} do
    assert {:error, {:unknown_source, "nope"}} = Pepe.Migrate.run("nope", from: src)
    assert {:error, {:home_not_found, _}} = Pepe.Migrate.run("openclaw", from: "/no/such/dir")
  end

  test "secret/1 normalizes env refs, named env sources and raw literals" do
    assert Pepe.Migrate.secret("${OPENAI_API_KEY}") == {"${OPENAI_API_KEY}", nil}
    assert {"${MY_KEY}", nil} = Pepe.Migrate.secret(%{"source" => "env", "id" => "MY_KEY"})
    assert {"raw-abc", note} = Pepe.Migrate.secret("raw-abc")
    assert note =~ "raw secret"
  end

  test "map_tools keeps ids that exist in Pepe and falls back to the default" do
    assert Pepe.Migrate.map_tools(["web_search", "bogus", "bash"], ["read_file"]) == ["web_search", "bash"]
    assert Pepe.Migrate.map_tools(["bogus"], ["read_file"]) == ["read_file"]
    assert Pepe.Migrate.map_tools([], ["read_file"]) == ["read_file"]
    assert Pepe.Migrate.map_tools(nil, ["read_file"]) == ["read_file"]
  end

  test "skills_in lists SKILL.md folders as {name, content}", %{src: src} do
    File.mkdir_p!(Path.join([src, "a"]))
    File.write!(Path.join([src, "a", "SKILL.md"]), "skill a")
    File.mkdir_p!(Path.join([src, "b"]))
    File.write!(Path.join([src, "b", "SKILL.md"]), "skill b")

    assert Enum.sort(Pepe.Migrate.skills_in(src)) == [{"a", "skill a"}, {"b", "skill b"}]
    assert Pepe.Migrate.skills_in("/no/such/dir") == []
  end

  test "detected/0 finds a source whose home exists" do
    exists = Path.join(System.tmp_dir!(), "hermes_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(exists)
    prev_h = System.get_env("HERMES_HOME")
    prev_o = System.get_env("OPENCLAW_STATE_DIR")
    System.put_env("HERMES_HOME", exists)
    System.put_env("OPENCLAW_STATE_DIR", "/definitely/not/here")

    on_exit(fn ->
      if prev_h, do: System.put_env("HERMES_HOME", prev_h), else: System.delete_env("HERMES_HOME")
      if prev_o, do: System.put_env("OPENCLAW_STATE_DIR", prev_o), else: System.delete_env("OPENCLAW_STATE_DIR")
      File.rm_rf(exists)
    end)

    assert "hermes" in Pepe.Migrate.detected()
    refute "openclaw" in Pepe.Migrate.detected()
  end
end
