defmodule Mix.Tasks.PepeAgentPromptCliTest do
  @moduledoc """
  `mix pepe agent prompt NAME` - dumps the fully-assembled system prompt
  (Pepe.Agent.Workspace.system_prompt/1), not just the agent's own `system_prompt` seed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config
  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_agent_prompt_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "prints the agent's seed plus the framework scaffolding around it" do
    Config.put_agent(%Agent{name: "assistant", system_prompt: "You are a terse assistant.", tools: []})

    out = pepe(["agent", "prompt", "assistant"])

    assert out =~ "You are a terse assistant."
    # Framework-injected scaffolding no test agent config ever wrote itself - proof this is the
    # assembled prompt, not just the raw seed field.
    assert out =~ "## Current time"
  end

  test "an unknown agent is a clean error, not a crash" do
    assert pepe_err(["agent", "prompt", "ghost"]) =~ "unknown agent: ghost"
  end

  test "--project scopes to that project's agent" do
    Config.add_project("acme")
    Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "Sell things.", tools: []})

    out = pepe(["agent", "prompt", "vendas", "--project", "acme"])
    assert out =~ "Sell things."
  end
end
