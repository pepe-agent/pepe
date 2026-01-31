defmodule Cortex.DoctorTest do
  use ExUnit.Case, async: false

  alias Cortex.Config
  alias Cortex.Doctor

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_doc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "flags unset ${ENV} references anywhere in the config" do
    var = "CORTEX_DOCTOR_MISSING_#{System.unique_integer([:positive])}"
    Config.put_model(%Config.Model{name: "m", base_url: "x", api_key: "${#{var}}", model: "id"})

    checks = Doctor.checks()
    assert {"env", ^var, {:error, _}} = List.keyfind(checks, var, 1)
    refute Doctor.healthy?(checks)
  end

  test "passes when the referenced env var is set" do
    var = "CORTEX_DOCTOR_SET_#{System.unique_integer([:positive])}"
    System.put_env(var, "value")
    Config.put_model(%Config.Model{name: "m", base_url: "x", api_key: "${#{var}}", model: "id"})

    checks = Doctor.checks()
    assert {"env", ^var, :ok} = List.keyfind(checks, var, 1)
    System.delete_env(var)
  end

  test "flags an agent pointing at a missing model and unknown tools" do
    Config.put_agent(%Config.Agent{name: "a", tools: ["bash", "made_up_tool"], model: "ghost"})

    checks = Doctor.checks()
    assert Enum.any?(checks, &match?({"agent", "a", {:error, _}}, &1))
    assert Enum.any?(checks, &match?({"agent", "a", {:warn, "unknown tools:" <> _}}, &1))
  end

  test "mcp__ tool names are considered known" do
    Config.put_model(%Config.Model{name: "m", base_url: "x", model: "id"})
    Config.set_default_model("m")
    Config.put_agent(%Config.Agent{name: "a", tools: ["mcp__sentry__find_organizations"]})

    checks = Doctor.checks()
    refute Enum.any?(checks, &match?({"agent", "a", {:warn, _}}, &1))
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

  test "the doctor tool summarizes problems" do
    Config.put_agent(%Config.Agent{name: "a", tools: [], model: "ghost"})

    assert {:ok, out} = Cortex.Tools.Doctor.run(%{}, %{})
    assert out =~ "issue"
    assert out =~ "[agent] a"
  end
end
