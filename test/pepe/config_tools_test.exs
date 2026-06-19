defmodule Pepe.Tools.ConfigToolsTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.ConfigGet
  alias Pepe.Tools.ConfigSet

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cfgtools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{name: "Codex", base_url: "x", model: "gpt-5.5"})
    Config.put_agent(%Config.Agent{name: "ZakAI", system_prompt: "x", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "config_get reports models, agents, language and telegram" do
    {:ok, text} = ConfigGet.run(%{}, %{})
    assert text =~ "Models: Codex"
    assert text =~ "Agents: default/ZakAI"
    assert text =~ "Language: en"
  end

  test "config_set changes the language when supported" do
    assert {:ok, _} = ConfigSet.run(%{"setting" => "language", "value" => "pt_BR"}, %{})
    assert Config.locale() == "pt_BR"
  end

  test "config_set rejects an unsupported language" do
    assert {:error, _} = ConfigSet.run(%{"setting" => "language", "value" => "fr"}, %{})
  end

  test "config_set sets the default model only if it exists" do
    assert {:ok, _} = ConfigSet.run(%{"setting" => "default_model", "value" => "Codex"}, %{})
    assert Config.default_model_name() == "Codex"

    assert {:error, _} = ConfigSet.run(%{"setting" => "default_model", "value" => "Nope"}, %{})
  end

  test "config_set with no args returns the schema (self-discovery)" do
    assert {:ok, schema} = ConfigSet.run(%{}, %{})
    assert schema =~ "timezone"
    assert schema =~ "default_model"
    assert schema =~ "Not editable here"
  end

  test "config_set is fail-closed for settings outside the allowlist" do
    assert {:error, msg} = ConfigSet.run(%{"setting" => "api_key", "value" => "x"}, %{})
    assert msg =~ "not editable"

    assert {:error, _} =
             ConfigSet.run(%{"setting" => "telegram.bot_token", "value" => "x"}, %{})
  end

  test "config_set validates and sets the timezone" do
    assert {:ok, _} =
             ConfigSet.run(%{"setting" => "timezone", "value" => "America/Sao_Paulo"}, %{})

    assert Config.default_timezone() == "America/Sao_Paulo"

    assert {:error, _} = ConfigSet.run(%{"setting" => "timezone", "value" => "Not/AZone"}, %{})
  end

  test "config_set toggles the default bot's telegram flags" do
    assert {:ok, _} =
             ConfigSet.run(%{"setting" => "telegram.require_mention", "value" => "false"}, %{})

    assert Config.telegram()["require_mention"] == false

    assert {:error, _} =
             ConfigSet.run(%{"setting" => "telegram.require_mention", "value" => "maybe"}, %{})
  end

  test "config_set adds env var names to secrets.expose_env, additively" do
    assert {:ok, _} =
             ConfigSet.run(
               %{"setting" => "secrets.expose_env", "value" => "OP_SERVICE_ACCOUNT_TOKEN"},
               %{}
             )

    assert "OP_SERVICE_ACCOUNT_TOKEN" in Config.expose_env()

    # A second call unions rather than replacing - both survive.
    assert {:ok, _} =
             ConfigSet.run(%{"setting" => "secrets.expose_env", "value" => "VAULT_TOKEN"}, %{})

    assert "OP_SERVICE_ACCOUNT_TOKEN" in Config.expose_env()
    assert "VAULT_TOKEN" in Config.expose_env()
  end

  test "config_set rejects an invalid env var name for secrets.expose_env" do
    assert {:error, _} =
             ConfigSet.run(%{"setting" => "secrets.expose_env", "value" => "not a name"}, %{})

    assert {:error, _} =
             ConfigSet.run(%{"setting" => "secrets.expose_env", "value" => ""}, %{})
  end
end
