defmodule Pepe.FlowTest do
  @moduledoc """
  `Pepe.Flow` - promoting a proven, identical tool-call sequence across real traces into
  a script that replays without calling the model, and only running what was already
  pre-approved (there is nobody watching a flow run, same as any other unattended surface).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Flow
  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_flow_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: ["read_file", "bash"]})
    dir = Pepe.Agent.Workspace.dir("assistant")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "note.txt"), "hello")

    {:ok, home: home}
  end

  defp record_trace(agent, calls) do
    assert Trace.start(agent, nil) == :started

    Enum.each(calls, fn {name, args} ->
      Trace.event({:tool_call, name, args})
      Trace.event({:tool_result, name, "ok"})
    end)

    Trace.finish({:ok, "done", []})
  end

  test "promotes two traces with the identical tool-call sequence into a flow" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])

    assert {:ok, flow} = Flow.promote_from_traces("read-note", "assistant", [id1, id2])
    assert flow["name"] == "read-note"
    # Stored under the agent's canonical handle, not whatever shorthand was passed in -
    # same resolution a cron's own `agent` field already goes through, so a "flow" cron
    # built later finds this under the exact handle it will be looked up with.
    assert flow["agent"] == "default/assistant"
    assert flow["steps"] == [%{"tool" => "read_file", "args" => ~s({"path":"note.txt"})}]
    assert flow["source_trace_ids"] == [id1, id2]

    assert Flow.get("assistant", "read-note") == flow
  end

  test "refuses when the traces don't carry the exact same sequence" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"other.txt"})}])

    assert Flow.promote_from_traces("read-note", "assistant", [id1, id2]) == {:error, :traces_dont_match}
    assert Flow.get("assistant", "read-note") == nil
  end

  test "refuses fewer than two traces - a single run proves nothing about reliability" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    assert Flow.promote_from_traces("read-note", "assistant", [id1]) == {:error, :need_at_least_two_traces}
  end

  test "refuses an unknown trace id" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    assert Flow.promote_from_traces("read-note", "assistant", [id1, "ghost"]) == {:error, :trace_not_found}
  end

  test "refuses to overwrite an existing flow unless asked to" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    {:ok, _} = Flow.promote_from_traces("read-note", "assistant", [id1, id2])

    assert Flow.promote_from_traces("read-note", "assistant", [id1, id2]) == {:error, :already_exists}
    assert {:ok, _} = Flow.promote_from_traces("read-note", "assistant", [id1, id2], overwrite: true)
  end

  test "run/1 replays a safe (always-allowed) step with no approval needed" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    {:ok, flow} = Flow.promote_from_traces("read-note", "assistant", [id1, id2])

    assert {:ok, [result]} = Flow.run(flow)
    assert result =~ "hello"

    reloaded = Flow.get("assistant", "read-note")
    assert reloaded["last_result"] == "ok"
    assert is_integer(reloaded["last_run"])
  end

  test "run/1 refuses a risky step the agent never pre-approved - nobody is watching a flow run" do
    id1 = record_trace("assistant", [{"bash", ~s({"command":"rm -rf /tmp/x"})}])
    id2 = record_trace("assistant", [{"bash", ~s({"command":"rm -rf /tmp/x"})}])
    {:ok, flow} = Flow.promote_from_traces("cleanup", "assistant", [id1, id2])

    assert {:error, {:denied, "bash", _reason}} = Flow.run(flow)

    reloaded = Flow.get("assistant", "cleanup")
    assert reloaded["last_result"] =~ "error"
  end

  test "run/1 replays a risky step the agent's auto_approve already covers" do
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", tools: ["bash"], auto_approve: ["bash:none"]})
    id1 = record_trace("assistant", [{"bash", ~s({"command":"echo hi"})}])
    id2 = record_trace("assistant", [{"bash", ~s({"command":"echo hi"})}])
    {:ok, flow} = Flow.promote_from_traces("greet", "assistant", [id1, id2])

    assert {:ok, [result]} = Flow.run(flow)
    assert result =~ "hi"
  end

  test "delete/2 removes a flow" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    {:ok, _} = Flow.promote_from_traces("read-note", "assistant", [id1, id2])

    assert Flow.delete("assistant", "read-note") == :ok
    assert Flow.get("assistant", "read-note") == nil
  end

  test "for_agent/1 lists an agent's flows sorted by name" do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    {:ok, _} = Flow.promote_from_traces("zeta", "assistant", [id1, id2])
    {:ok, _} = Flow.promote_from_traces("alpha", "assistant", [id1, id2], overwrite: true)

    assert Enum.map(Flow.for_agent("assistant"), & &1["name"]) == ["alpha", "zeta"]
  end
end
