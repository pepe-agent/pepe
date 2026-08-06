defmodule Pepe.Agent.HarnessTest do
  @moduledoc """
  `Pepe.Agent.Runtime` dispatches the "harness" slot itself, not through
  `Pepe.Slots.Guard` - see `Pepe.Agent.Harness`'s moduledoc for why. These tests exercise
  that dispatch directly (`Pepe.Agent.Runtime.run/3`), not `Pepe.Slots.Guard.call/4`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_harness_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "with no harness plugin installed, the builtin loop runs the model as before" do
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    model = %Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"}
    agent = %Agent{name: "no-harness", system_prompt: "x", tools: []}

    assert {:ok, content, _messages} = Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: model)
    assert content =~ "Hello from the mock!"
  end

  test "a plugin pinned to the harness slot replaces the loop entirely - the model is never called", %{home: home} do
    write_harness(home, "PepeHarnessTest.Fake", "fake_harness", "def run(_agent, messages, _opts), do: {:ok, \"custom answer\", messages}")
    Config.put_slot("harness", "fake_harness")

    # A model nothing could actually reach - proves the builtin loop's own model call
    # never happens when a harness occupies the slot.
    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    agent = %Agent{name: "harnessed", system_prompt: "x", tools: []}

    assert {:ok, "custom answer", _messages} =
             Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model)
  end

  test "a crashing harness plugin returns an error rather than silently falling back to the builtin", %{home: home} do
    write_harness(home, "PepeHarnessTest.Boom", "boom_harness", "def run(_agent, _messages, _opts), do: raise(\"boom\")")
    Config.put_slot("harness", "boom_harness")

    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    agent = %Agent{name: "harnessed-boom", system_prompt: "x", tools: []}

    assert {:error, {:crashed, _}} = Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model)
  end

  test "a harness plugin returning a malformed shape is treated as a failure, not passed through", %{home: home} do
    write_harness(home, "PepeHarnessTest.Malformed", "malformed_harness", "def run(_agent, _messages, _opts), do: :not_the_right_shape")
    Config.put_slot("harness", "malformed_harness")

    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    agent = %Agent{name: "harnessed-malformed", system_prompt: "x", tools: []}

    assert {:error, {:bad_return, :not_the_right_shape}} =
             Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model)
  end

  test "an agent's own slots override selects a harness only for that agent", %{home: home} do
    write_harness(home, "PepeHarnessTest.Mine", "mine_harness", "def run(_agent, messages, _opts), do: {:ok, \"mine\", messages}")

    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    overridden = %Agent{name: "solo", system_prompt: "x", tools: [], slots: %{"harness" => "mine_harness"}}

    assert {:ok, "mine", _} = Pepe.Agent.Runtime.run(overridden, [Message.user("hi")], model: dead_model)

    # No agent-level override and nothing pinned globally: falls straight through to the
    # builtin, which does try to reach the (unreachable) model and fails transiently.
    plain = %Agent{name: "plain", system_prompt: "x", tools: []}
    assert {:error, _} = Pepe.Agent.Runtime.run(plain, [Message.user("hi")], model: dead_model)
  end

  test "a plugin harness sees opts[:untrusted] taint, and starts clean when it isn't set", %{home: home} do
    write_harness(
      home,
      "PepeHarnessTest.TaintCheck",
      "taint_check_harness",
      "def run(_agent, messages, _opts), do: {:ok, to_string(Pepe.Permissions.tainted?(%{})), messages}"
    )

    Config.put_slot("harness", "taint_check_harness")

    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    agent = %Agent{name: "taint-check", system_prompt: "x", tools: []}

    assert {:ok, "true", _} = Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model, untrusted: true)
    assert {:ok, "false", _} = Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model)
  end

  @recorder_target :pepe_harness_test_recorder

  test "Trace/RunObservers still wrap a harness-driven run the same as any other", %{home: home} do
    write_harness(home, "PepeHarnessTest.Observed", "observed_harness", "def run(_agent, messages, _opts), do: {:ok, \"done\", messages}")
    Config.put_slot("harness", "observed_harness")
    write_recorder(home, "recorder")

    dead_model = %Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
    agent = %Agent{name: "observed-agent", system_prompt: "x", tools: []}

    assert {:ok, "done", _} = Pepe.Agent.Runtime.run(agent, [Message.user("hi")], model: dead_model)
    assert_receive {:observed, :run_start, _}, 1_000
    assert_receive {:observed, :run_end, _}, 1_000
  end

  defp write_harness(home, module, name, body) do
    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule #{module} do
      @behaviour Pepe.Agent.Harness
      def name, do: "#{name}"
      def slot, do: "harness"
      #{body}
    end
    """)
  end

  defp write_recorder(home, name) do
    Process.register(self(), @recorder_target)

    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule PepeHarnessTest.Recorder do
      @behaviour Pepe.Agent.RunObserver
      def name, do: "#{name}"
      def subscriptions, do: [:run_start, :run_end]

      def handle_event(event, payload, _meta) do
        send(Process.whereis(#{inspect(@recorder_target)}), {:observed, event, payload})
      end
    end
    """)
  end
end
