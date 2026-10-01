defmodule Pepe.DecisionConnectionTest do
  @moduledoc """
  A decision-only connection exists to sort messages, never to chat: it is a model
  connection like any other, but every place that lets a person pick a model for
  conversation leaves it out, and the one place it belongs (the triage model) takes it.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.ModelSwitch
  alias Pepe.Tools.ManageAgent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_decconn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_model(%Model{name: "gpt", base_url: "http://x", api_key: "k", model: "m"})
    Config.put_model(%Model{name: "jev", base_url: "http://y", api_key: "k", model: "jev-latest", api: "typesafe-systemone"})
    Config.put_agent(%Agent{name: "sales", model: "gpt", system_prompt: "x", tools: []})
    :ok
  end

  defp ctx, do: %{agent: %Agent{name: "admin", can_manage: ["*"]}, authorize: nil}

  test "the catalog has a TypeSafe entry that makes a decision connection" do
    provider = Pepe.Providers.get("typesafe")

    assert provider.api == "typesafe-systemone"
    assert provider.base_url == "https://api.typesafe.ai/v1/systemone"
    assert Enum.any?(Pepe.Providers.auth_methods(provider), &(&1[:api] == "typesafe-systemone"))
  end

  test "only chat connections are listed for conversation, a fallback or a chore" do
    assert Enum.map(Config.chat_models(), & &1.name) == ["gpt"]
    assert "jev" in Enum.map(Config.models(), & &1.name)

    assert PepeWeb.DashData.model_names() == ["gpt"]
    assert PepeWeb.DashData.triage_names() == ["gpt", "jev"]
    assert Enum.map(ModelSwitch.list_for(nil), & &1.name) == ["gpt"]
  end

  test "switching a conversation to it is refused, same as an unknown model" do
    assert {:error, :unknown_model} = ModelSwitch.apply("k", "sales", "jev", :session)
    assert {:error, :unknown_model} = ModelSwitch.apply("k", "sales", "jev", :global)
  end

  test "by chat: not as the model or the chores model, yes as the triage model, and empty turns it off" do
    assert {:error, message} = ManageAgent.run(%{"action" => "set_model", "target" => "sales", "value" => "jev"}, ctx())
    assert message =~ "only makes decisions"

    assert {:error, message} = ManageAgent.run(%{"action" => "set_utility_model", "target" => "sales", "value" => "jev"}, ctx())
    assert message =~ "only makes decisions"

    assert {:ok, _} = ManageAgent.run(%{"action" => "set_triage_model", "target" => "sales", "value" => "jev"}, ctx())
    assert Config.get_agent("sales").triage_model == "jev"

    assert {:ok, _} = ManageAgent.run(%{"action" => "set_triage_model", "target" => "sales", "value" => ""}, ctx())
    assert Config.get_agent("sales").triage_model == nil

    assert {:error, "no model connection named nope"} =
             ManageAgent.run(%{"action" => "set_triage_model", "target" => "sales", "value" => "nope"}, ctx())
  end
end
