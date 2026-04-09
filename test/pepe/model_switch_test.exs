defmodule Pepe.ModelSwitchTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.ModelSwitch

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_modelswitch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "list_for/1" do
    test "filters models by company, root scope is unprefixed handles" do
      Config.put_model(%Model{name: "root-model", base_url: "https://x", model: "gpt"})
      Config.put_model(%Model{name: "acme/model-a", base_url: "https://x", model: "gpt"})
      Config.put_model(%Model{name: "acme/model-b", base_url: "https://x", model: "gpt"})
      Config.put_model(%Model{name: "globex/model-c", base_url: "https://x", model: "gpt"})

      assert Enum.map(ModelSwitch.list_for(nil), & &1.name) == ["root-model"]
      assert Enum.map(ModelSwitch.list_for("acme"), & &1.name) == ["acme/model-a", "acme/model-b"]
      assert Enum.map(ModelSwitch.list_for("globex"), & &1.name) == ["globex/model-c"]
      assert ModelSwitch.list_for("no-such-company") == []
    end
  end

  describe "permission/2" do
    test "a trainer always gets :global, locked or not" do
      assert ModelSwitch.permission(true, false) == :global
      assert ModelSwitch.permission(true, true) == :global
    end

    test "a non-trainer gets :session unless locked, then :none" do
      assert ModelSwitch.permission(false, false) == :session
      assert ModelSwitch.permission(false, true) == :none
    end
  end

  describe "apply/4" do
    setup do
      Config.put_model(%Model{name: "model-a", base_url: "https://x", model: "gpt-a"})
      Config.put_model(%Model{name: "model-b", base_url: "https://x", model: "gpt-b"})
      Config.put_agent(%Agent{name: "assistant", system_prompt: "x", model: "model-a"})
      key = "test:apply:#{System.unique_integer([:positive])}"
      {:ok, _pid} = SessionSupervisor.ensure(key, "assistant")
      %{key: key}
    end

    test ":session sets an in-memory override, never touches the agent's config", %{key: key} do
      assert :ok = ModelSwitch.apply(key, "assistant", "model-b", :session)

      assert Session.status(key).model == "gpt-b"
      # The persisted agent definition is untouched.
      assert Config.get_agent("assistant").model == "model-a"
    end

    test ":global persists the change on the agent", %{key: key} do
      assert :ok = ModelSwitch.apply(key, "assistant", "model-b", :global)

      assert Config.get_agent("assistant").model == "model-b"
      assert Session.status(key).model == "gpt-b"
    end

    test ":session with an unknown model is refused", %{key: key} do
      assert {:error, :unknown_model} = ModelSwitch.apply(key, "assistant", "ghost", :session)
      assert Config.get_agent("assistant").model == "model-a"
    end

    test ":global with an unknown model is refused", %{key: key} do
      assert {:error, :unknown_model} = ModelSwitch.apply(key, "assistant", "ghost", :global)
      assert Config.get_agent("assistant").model == "model-a"
    end

    test ":global against an unknown agent is refused", %{key: key} do
      assert {:error, :unknown_agent} = ModelSwitch.apply(key, "ghost-agent", "model-b", :global)
    end
  end
end
