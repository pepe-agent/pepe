defmodule Mix.Tasks.PepeEvalModelsCliTest do
  @moduledoc """
  `mix pepe eval SUITE --models a,b` - side-by-side model comparison, driven through
  the real CLI dispatch (not just `Pepe.Eval.run_suite/2` directly).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_eval_models_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "evals"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, ok_server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, ok_port}} = ThousandIsland.listener_info(ok_server)

    on_exit(fn ->
      Process.exit(ok_server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_model(%Model{name: "good", base_url: "http://localhost:#{ok_port}", api_key: "x", model: "good-model"})
    # No live server on this port - proves each named model is actually dispatched to,
    # not just the first one repeated.
    Config.put_model(%Model{name: "broken", base_url: "http://127.0.0.1:1", api_key: "x", model: "broken-model"})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: [], model: "good"})

    cases = [%{"name" => "greets", "agent" => "assistant", "prompt" => "hi", "expect" => %{"contains" => ["hello"]}}]
    File.write!(Path.join([home, "evals", "greet.json"]), Jason.encode!(cases))

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "runs the suite against each named model and reports a per-model summary" do
    out = pepe(["eval", "greet", "--models", "good,broken"])

    assert out =~ "== good =="
    assert out =~ "== broken =="
    assert out =~ "summary"
    assert out =~ "good"
    assert out =~ "1/1 passed"
    assert out =~ "broken"
    assert out =~ "0/1 passed"
  end

  test "--models with no suite runs every suite against each model" do
    out = pepe(["eval", "--models", "good"])

    assert out =~ "▸ greet"
    assert out =~ "== good =="
  end

  test "an empty --models value is a usage error, not a silent no-op" do
    out = pepe_err(["eval", "greet", "--models", ""])
    assert out =~ "usage: mix pepe eval"
  end
end
