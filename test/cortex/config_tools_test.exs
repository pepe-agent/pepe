defmodule Cortex.Tools.ConfigToolsTest do
  use ExUnit.Case, async: false

  alias Cortex.Config
  alias Cortex.Tools.ConfigGet
  alias Cortex.Tools.ConfigSet

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_cfgtools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    Config.put_model(%Config.Model{name: "Codex", base_url: "x", model: "gpt-5.5"})
    Config.put_agent(%Config.Agent{name: "ZakAI", system_prompt: "x", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "config_get reports models, agents, language and telegram" do
    {:ok, text} = ConfigGet.run(%{}, %{})
    assert text =~ "Models: Codex"
    assert text =~ "Agents: ZakAI"
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
end
