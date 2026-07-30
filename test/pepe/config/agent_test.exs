defmodule Pepe.Config.AgentTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_agentcfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "from_map/1 tools default" do
    test "a map with no \"tools\" key defaults to every built-in tool, not none" do
      agent = Agent.from_map(%{"name" => "fresh"})

      assert agent.tools == Pepe.Tools.names()
      assert "send_file" in agent.tools
      assert "bash" in agent.tools
    end

    test "an explicit empty list is respected as \"no tools\", not coalesced to the default" do
      agent = Agent.from_map(%{"name" => "locked-down", "tools" => []})

      assert agent.tools == []
    end

    test "an explicit tools list is used as-is" do
      agent = Agent.from_map(%{"name" => "narrow", "tools" => ["read_file"]})

      assert agent.tools == ["read_file"]
    end
  end
end
