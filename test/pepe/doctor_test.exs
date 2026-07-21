defmodule Pepe.DoctorTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Doctor

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_doc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "flags unset ${ENV} references anywhere in the config" do
    var = "PEPE_DOCTOR_MISSING_#{System.unique_integer([:positive])}"
    Config.put_model(%Config.Model{name: "m", base_url: "x", api_key: "${#{var}}", model: "id"})

    checks = Doctor.checks()
    assert {"env", ^var, {:error, _}} = List.keyfind(checks, var, 1)
    refute Doctor.healthy?(checks)
  end

  test "flags an unrecognized top-level config key - a typo doing nothing silently" do
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})
    Config.save(Map.put(Config.load(), "telegran", %{"bot_token" => "x"}))

    checks = Doctor.checks()
    assert {"config", "telegran", {:warn, msg}} = List.keyfind(checks, "telegran", 1)
    assert msg =~ "unknown top-level config key"
  end

  test "a config with only known top-level keys passes cleanly" do
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    checks = Doctor.checks()
    assert {"config", "top-level keys", :ok} = List.keyfind(checks, "top-level keys", 1)
  end

  test "passes when the referenced env var is set" do
    var = "PEPE_DOCTOR_SET_#{System.unique_integer([:positive])}"
    System.put_env(var, "value")
    Config.put_model(%Config.Model{name: "m", base_url: "x", api_key: "${#{var}}", model: "id"})

    checks = Doctor.checks()
    assert {"env", ^var, :ok} = List.keyfind(checks, var, 1)
    System.delete_env(var)
  end

  test "flags an agent pointing at a missing model and unknown tools" do
    Config.put_agent(%Config.Agent{name: "a", tools: ["bash", "made_up_tool"], model: "ghost"})

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"agent", "default/a", {:error, _}}, &1))
    assert Enum.any?(checks, &match?({"agent", "default/a", {:warn, "unknown tools:" <> _}}, &1))
  end

  test "mcp__ tool names are considered known" do
    Config.put_model(%Config.Model{name: "m", base_url: "x", model: "id"})
    Config.set_default_model("m")
    Config.put_agent(%Config.Agent{name: "a", tools: ["mcp__sentry__find_organizations"]})

    checks = Doctor.checks()
    refute Enum.any?(checks, &match?({"agent", "default/a", {:warn, _}}, &1))
  end

  test "flags a cron with a bad schedule, timezone or agent" do
    Config.put_cron(%Config.Cron{
      id: "bad",
      name: "bad",
      agent: "ghost",
      prompt: "x",
      schedule: "not a cron",
      timezone: "Nope/Zone"
    })

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"cron", "bad", {:error, _}}, &1))
    assert Enum.any?(checks, &match?({"cron", "bad tz", {:error, _}}, &1))
    assert Enum.any?(checks, &match?({"cron", "bad agent", {:error, _}}, &1))
  end

  test "security: flags a plaintext secret but not a ${ENV} reference, and a missing password" do
    Config.put_model(%Config.Model{name: "raw", base_url: "x", api_key: "sk-plaintext-key", model: "id"})
    Config.put_model(%Config.Model{name: "safe", base_url: "x", api_key: "${SOME_ENV}", model: "id2"})

    checks = Doctor.checks()

    plaintext = Enum.filter(checks, &match?({"security", "plaintext secret at" <> _, {:warn, _}}, &1))
    assert [_] = plaintext
    assert Enum.any?(checks, &match?({"security", "dashboard password", {:warn, _}}, &1))
  end

  test "security: a commitment/watch's origin.key (a session key, not a credential) is not a false positive" do
    Config.put_commitment(%Config.Commitment{
      id: "c1",
      text: "renew the cert",
      origin: %{"channel" => "telegram", "key" => "telegram:123456"}
    })

    checks = Doctor.checks()

    refute Enum.any?(checks, &match?({"security", "plaintext secret at" <> _, _}, &1))
  end

  test "security: a real credential that ended up under origin.key is still caught" do
    Config.put_commitment(%Config.Commitment{
      id: "c2",
      text: "renew the cert",
      origin: %{"channel" => "telegram", "key" => "sk-live-abcdefghijklmnopqrstuvwx"}
    })

    checks = Doctor.checks()

    assert Enum.any?(checks, &match?({"security", "plaintext secret at" <> _, {:warn, _}}, &1))
  end

  # Regression: found on a real production install (Nexus) - an OAuth-connected model (Codex,
  # signed in via `Pepe.OAuth`) tripped 5 separate "plaintext secret" warnings, none of them a
  # human-typed credential: token_url/client_id/token_content_type/provider/expires_at are the
  # provider's own fixed flow spec (`Pepe.Providers`), written verbatim by
  # `Pepe.OAuth.subscription_connection/4`, never something a person pasted in. `refresh` and
  # `api_key` ARE live credentials, but ones `Pepe.OAuth.persist_refresh/3` rewrites on every
  # token refresh - there is no `${ENV_VAR}` either could become, so warning "move it to an env
  # var" is actively wrong advice for them, not just noisy.
  test "security: an OAuth-connected model's own bookkeeping is not a plaintext-secret false positive" do
    Config.put_model(%Config.Model{
      name: "codex",
      base_url: "https://api.openai.com/v1",
      api_key: "live-access-token-abcdefghijklmnopqrstuvwxyz",
      model: "gpt-5-codex",
      oauth: %{
        "provider" => "codex",
        "refresh" => "live-refresh-token-abcdefghijklmnopqrstuvwxyz",
        "expires_at" => 1_800_000_000,
        "token_url" => "https://auth.openai.com/oauth/token",
        "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
        "token_content_type" => "json"
      }
    })

    checks = Doctor.checks()

    refute Enum.any?(checks, &match?({"security", "plaintext secret at" <> _, _}, &1))
  end

  test "security: a model's api_key with no oauth is still caught, even if it looks token-shaped" do
    Config.put_model(%Config.Model{
      name: "plain",
      base_url: "x",
      api_key: "live-access-token-abcdefghijklmnopqrstuvwxyz",
      model: "id"
    })

    checks = Doctor.checks()

    assert Enum.any?(checks, fn
             {"security", "plaintext secret at " <> subject, {:warn, _}} -> subject =~ ".api_key"
             _ -> false
           end)
  end

  # Regression: same production install - an MCP server's launcher script path
  # ("/data/projects/default/agents/admin/scripts/github-mcp.sh") tripped the value-shape
  # heuristic (long, made only of the characters a credential is made of), even though the
  # actual secret lives inside that script's own environment, never in config.json.
  test "security: an MCP command that is a long file path is not a plaintext-secret false positive" do
    Config.put_mcp_server("github", %{"command" => "/data/projects/default/agents/admin/scripts/github-mcp.sh"})

    checks = Doctor.checks()

    refute Enum.any?(checks, &match?({"security", "plaintext secret at" <> _, _}, &1))
  end

  test "channel: flags an unknown provider and a missing agent" do
    Config.put_webhook("bad", %{"provider" => "nope", "agent" => "x", "config" => %{}})
    Config.put_webhook("good", %{"provider" => "slack", "agent" => "ghost", "config" => %{}})

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"channel", "bad", {:error, _}}, &1))
    assert Enum.any?(checks, &match?({"channel", "good", {:error, _}}, &1))
  end

  test "state: flags an orphan agent directory on disk" do
    home = System.get_env("PEPE_HOME")
    File.mkdir_p!(Path.join([home, "projects", "default", "agents", "ghostdir"]))

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"state", "orphan agent dir default/ghostdir", {:warn, _}}, &1))
  end

  test "plugin: flags an .exs that doesn't parse" do
    home = System.get_env("PEPE_HOME")
    File.mkdir_p!(Path.join(home, "plugins"))
    File.write!(Path.join([home, "plugins", "broken.exs"]), "defmodule Broken do def x(  end")

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"plugin", "broken.exs", {:error, "doesn't parse"}}, &1))
  end

  test "skill: flags an empty user skill file" do
    home = System.get_env("PEPE_HOME")
    File.mkdir_p!(Path.join(home, "skills"))
    File.write!(Path.join([home, "skills", "empty.md"]), "   \n")

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"skill", "empty", {:warn, _}}, &1))
  end

  test "the doctor tool summarizes problems" do
    Config.put_agent(%Config.Agent{name: "a", tools: [], model: "ghost"})

    assert {:ok, out} = Pepe.Tools.Doctor.run(%{}, %{})
    assert out =~ "issue"
    assert out =~ "[agent] default/a"
  end

  test "flags a config file that other users on the machine can read" do
    Config.save(%{"x" => 1})
    # Run once so the config is normalized and settled (a first run rewrites a minimal config,
    # which would reset the mode); then loosen it to simulate a config left world-readable.
    Doctor.checks()
    File.chmod!(Config.path(), 0o644)

    checks = Doctor.checks()

    assert {"security", "config file permissions", {:warn, msg}} =
             List.keyfind(checks, "config file permissions", 1)

    assert msg =~ "chmod 600"
  end

  test "does not flag a correctly-restricted config" do
    Config.save(%{"x" => 1})
    checks = Doctor.checks()
    assert List.keyfind(checks, "config file permissions", 1) == nil
  end
end
