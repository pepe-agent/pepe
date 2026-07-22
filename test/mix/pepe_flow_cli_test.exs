defmodule Mix.Tasks.PepeFlowCliTest do
  @moduledoc """
  `mix pepe flow` - promote/list/show/remove/run, driven through the real CLI dispatch.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_flow_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: ["read_file"]})
    dir = Pepe.Agent.Workspace.dir("assistant")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "note.txt"), "hello")

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  defp record_trace(agent, calls) do
    # Real usage (Pepe.Agent.Runtime) always starts a trace under the agent's already-
    # canonical `.name`, and always logs a tool_result alongside each tool_call - matching
    # both here is what makes promote_from_traces/4's "these traces all belong to this
    # agent, and every call in them actually succeeded" checks (Pepe.Flow) meaningful.
    canonical = Config.get_agent(agent).name
    assert Trace.start(canonical, nil) == :started

    Enum.each(calls, fn {name, args} ->
      Trace.event({:tool_call, name, args})
      Trace.event({:tool_result, name, "ok"})
    end)

    Trace.finish({:ok, "done", []})
  end

  test "promote, list, and show a flow end to end" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])

    out = pepe(["flow", "promote", "read-note", "--agent", "assistant", "--from", "#{id1},#{id2}"])
    assert out =~ "promoted"
    assert out =~ "read-note"
    assert out =~ "read_file"

    listing = pepe(["flow", "list", "--agent", "assistant"])
    assert listing =~ "read-note"
    assert listing =~ "never run"

    shown = pepe(["flow", "show", "assistant", "read-note"])
    assert shown =~ "read-note"
    assert shown =~ "read_file"
  end

  test "promote refuses with a clear reason when traces don't match" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"other.txt"})}])

    err = pepe_err(["flow", "promote", "read-note", "--agent", "assistant", "--from", "#{id1},#{id2}"])
    assert err =~ "didn't make the exact same tool calls"
  end

  test "run replays the flow's steps" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    pepe(["flow", "promote", "read-note", "--agent", "assistant", "--from", "#{id1},#{id2}"])

    out = pepe(["flow", "run", "assistant", "read-note"])
    assert out =~ "ran read-note"
    assert out =~ "1 step(s) completed"
  end

  test "remove deletes a flow" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    pepe(["flow", "promote", "read-note", "--agent", "assistant", "--from", "#{id1},#{id2}"])

    out = pepe(["flow", "remove", "assistant", "read-note"])
    assert out =~ "removed read-note"

    err = pepe_err(["flow", "show", "assistant", "read-note"])
    assert err =~ "no flow"
  end
end
