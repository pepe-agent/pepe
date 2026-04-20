defmodule Pepe.EvalTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Eval

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_eval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "evals"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: [], model: "mock"})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "evaluate/3 (pure assertions)" do
    test "no expectations always passes" do
      assert Eval.evaluate(%{}, "anything", []) == []
    end

    test "contains / not_contains are case-insensitive" do
      assert Eval.evaluate(%{"contains" => ["Hello"]}, "hello world", []) == []
      assert [msg] = Eval.evaluate(%{"contains" => ["bye"]}, "hello", [])
      assert msg =~ "missing"

      assert Eval.evaluate(%{"not_contains" => ["err"]}, "all good", []) == []
      assert [_] = Eval.evaluate(%{"not_contains" => ["Error"]}, "an error", [])
    end

    test "matches applies a regex; bad regex is a failure" do
      assert Eval.evaluate(%{"matches" => "h.llo"}, "hello", []) == []
      assert [_] = Eval.evaluate(%{"matches" => "^bye"}, "hello", [])
      assert ["invalid regex" <> _] = Eval.evaluate(%{"matches" => "("}, "hello", [])
    end

    test "tool_called / tool_not_called check the tools that ran" do
      assert Eval.evaluate(%{"tool_called" => ["web_search"]}, "x", ["web_search"]) == []
      assert [_] = Eval.evaluate(%{"tool_called" => ["web_search"]}, "x", [])
      assert Eval.evaluate(%{"tool_not_called" => ["bash"]}, "x", ["web_search"]) == []
      assert [_] = Eval.evaluate(%{"tool_not_called" => ["bash"]}, "x", ["bash"])
    end
  end

  test "run_case runs the agent and reports pass/fail on the reply" do
    pass = Eval.run_case(%{"name" => "greets", "agent" => "assistant", "prompt" => "say hi", "expect" => %{"contains" => ["hello"]}})

    assert pass.passed
    assert pass.reply =~ "Hello from the mock!"
    assert pass.failures == []

    fail = Eval.run_case(%{"name" => "nope", "agent" => "assistant", "prompt" => "say hi", "expect" => %{"contains" => ["xyz"]}})

    refute fail.passed
    assert [_] = fail.failures
  end

  test "run_suite loads and runs a suite file" do
    cases = [%{"name" => "greets", "agent" => "assistant", "prompt" => "say hi", "expect" => %{"matches" => "Hello"}}]
    File.write!(Path.join([Config.home(), "evals", "custom.json"]), Jason.encode!(cases))

    assert "custom" in Eval.suites()
    assert [%{passed: true, name: "greets"}] = Eval.run_suite("custom")
  end

  test "bundled suites are discoverable and loadable with no user files" do
    suites = Eval.suites()
    assert "arithmetic" in suites
    assert "safety" in suites
    assert Eval.load("arithmetic") != []
  end

  test "a user suite shadows the bundled one with the same name" do
    one = [%{"name" => "only", "prompt" => "x", "expect" => %{}}]
    File.write!(Path.join([Config.home(), "evals", "arithmetic.json"]), Jason.encode!(one))
    assert [%{"name" => "only"}] = Eval.load("arithmetic")
  end

  test "seed copies bundled suites into the user dir, skipping existing" do
    written = Eval.seed()
    assert "arithmetic" in written
    assert File.exists?(Path.join([Config.home(), "evals", "arithmetic.json"]))
    assert Eval.seed() == []
  end
end
