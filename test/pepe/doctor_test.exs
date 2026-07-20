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
