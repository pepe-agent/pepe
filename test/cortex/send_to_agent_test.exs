defmodule Cortex.Tools.SendToAgentTest do
  use ExUnit.Case, async: false

  alias Cortex.Config
  alias Cortex.Config.Agent
  alias Cortex.Config.Model
  alias Cortex.Tools.SendToAgent

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_a2a_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(from, chain \\ nil), do: %{agent: from, agent_chain: chain}

  test "refuses an agent that isn't in can_message" do
    from = %Agent{name: "A", can_message: ["B"]}
    assert {:error, msg} = SendToAgent.run(%{"to" => "C", "message" => "hi"}, ctx(from))
    assert msg =~ "not allowed"
  end

  test "refuses an unknown agent even if routed" do
    from = %Agent{name: "A", can_message: ["ghost"]}
    assert {:error, msg} = SendToAgent.run(%{"to" => "ghost", "message" => "hi"}, ctx(from))
    assert msg =~ "Unknown agent"
  end

  test "refuses a cycle (target already in the chain)" do
    Config.put_agent(%Agent{name: "B", system_prompt: "x"})
    from = %Agent{name: "X", can_message: ["B"]}

    assert {:error, msg} =
             SendToAgent.run(%{"to" => "B", "message" => "hi"}, ctx(from, ["X", "B"]))

    assert msg =~ "loop"
  end

  test "refuses when the chain is too deep" do
    Config.put_agent(%Agent{name: "B", system_prompt: "x"})
    from = %Agent{name: "A", can_message: ["B"]}
    deep = ["a", "b", "c", "d", "e"]

    assert {:error, msg} = SendToAgent.run(%{"to" => "B", "message" => "hi"}, ctx(from, deep))
    assert msg =~ "too deep"
  end

  test "delivers the message and returns the callee's reply" do
    {:ok, server} = Bandit.start_link(plug: Cortex.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Config.put_agent(%Agent{name: "B", model: "mock", system_prompt: "You are B.", tools: []})
    from = %Agent{name: "A", can_message: ["B"]}

    assert {:ok, out} = SendToAgent.run(%{"to" => "B", "message" => "hello"}, ctx(from))
    assert out =~ "B replied:"
    assert out =~ "Hello from the mock!"
  end
end
