defmodule Pepe.ModelChainTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_chain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a"})
    Config.put_model(%Model{name: "connection-backup", base_url: "https://x", model: "gpt-b"})
    Config.put_model(%Model{name: "agent-backup", base_url: "https://x", model: "gpt-c"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "with no agent override, the chain is the connection's own fallbacks" do
    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a", fallbacks: ["connection-backup"]})
    agent = %Agent{name: "a", model: "primary"}

    assert Enum.map(Config.model_chain_for_agent(agent), & &1.name) == ["primary", "connection-backup"]
  end

  test "an explicit agent-level list overrides the connection's own fallbacks" do
    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a", fallbacks: ["connection-backup"]})
    agent = %Agent{name: "a", model: "primary", fallbacks: ["agent-backup"]}

    assert Enum.map(Config.model_chain_for_agent(agent), & &1.name) == ["primary", "agent-backup"]
  end

  test "an explicit empty list opts this agent out of fallback entirely" do
    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a", fallbacks: ["connection-backup"]})
    agent = %Agent{name: "a", model: "primary", fallbacks: []}

    assert Enum.map(Config.model_chain_for_agent(agent), & &1.name) == ["primary"]
  end

  test "a missing name in either list is dropped, not crashed on" do
    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a"})
    agent = %Agent{name: "a", model: "primary", fallbacks: ["ghost", "agent-backup"]}

    assert Enum.map(Config.model_chain_for_agent(agent), & &1.name) == ["primary", "agent-backup"]
  end

  test "an agent whose model reference doesn't resolve falls through to the default and still yields a chain" do
    agent = %Agent{name: "a", model: "no-such-model"}
    assert Enum.map(Config.model_chain_for_agent(agent), & &1.name) == ["primary"]
  end
end
