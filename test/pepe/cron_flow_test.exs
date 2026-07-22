defmodule Pepe.CronFlowTest do
  @moduledoc """
  A cron of kind "flow" replays a promoted `Pepe.Flow` on a schedule, calling no model
  at all - see `Pepe.Flow`'s moduledoc for the design this reuses.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Flow
  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cron_flow_#{System.unique_integer([:positive])}")
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

  defp record_trace(agent, calls) do
    # See Pepe.FlowTest's own record_trace/2 for why this canonicalizes the agent and
    # logs a tool_result alongside each tool_call.
    canonical = Config.get_agent(agent).name
    assert Trace.start(canonical, nil) == :started

    Enum.each(calls, fn {name, args} ->
      Trace.event({:tool_call, name, args})
      Trace.event({:tool_result, name, "ok"})
    end)

    Trace.finish({:ok, "done", []})
  end

  defp promoted_flow(name) do
    id1 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    id2 = record_trace("assistant", [{"read_file", ~s({"path":"note.txt"})}])
    {:ok, flow} = Flow.promote_from_traces(name, "assistant", [id1, id2])
    flow
  end

  test "a flow-kind cron replays the flow's steps and records the outcome" do
    promoted_flow("read-note")

    cron = %Cron{
      id: "c1",
      name: "read-note",
      agent: "assistant",
      kind: "flow",
      flow: "read-note",
      schedule: "0 8 * * *",
      timezone: "Etc/UTC",
      deliver: "none",
      enabled: true
    }

    assert {:ok, output} = Pepe.Cron.run(cron, :manual)
    assert output =~ "completed"
    assert output =~ "1 step(s)"
  end

  test "a flow-kind cron refers to a flow that no longer exists" do
    cron = %Cron{
      id: "c1",
      name: "ghost",
      agent: "assistant",
      kind: "flow",
      flow: "ghost",
      schedule: "0 8 * * *",
      timezone: "Etc/UTC",
      deliver: "none",
      enabled: true
    }

    assert {:error, {:unknown_flow, "ghost"}} = Pepe.Cron.run(cron, :manual)
  end

  test "a flow-kind cron refuses a step the agent never pre-approved, same as running it directly" do
    id1 = record_trace("assistant", [{"bash", ~s({"command":"rm -rf /tmp/x"})}])
    id2 = record_trace("assistant", [{"bash", ~s({"command":"rm -rf /tmp/x"})}])
    {:ok, _} = Flow.promote_from_traces("cleanup", "assistant", [id1, id2])

    cron = %Cron{
      id: "c1",
      name: "cleanup",
      agent: "assistant",
      kind: "flow",
      flow: "cleanup",
      schedule: "0 8 * * *",
      timezone: "Etc/UTC",
      deliver: "none",
      enabled: true
    }

    assert {:error, {:denied, "bash", _}} = Pepe.Cron.run(cron, :manual)
  end

  test "mix pepe flow schedule creates a flow-kind cron" do
    promoted_flow("read-note")

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Pepe.dispatch(["flow", "schedule", "assistant", "read-note", "--schedule", "0 8 * * *"])
      end)

    assert out =~ "scheduled flow"

    cron = Config.get_cron("read-note")
    assert cron.kind == "flow"
    assert cron.flow == "read-note"
    # Same agent-handle resolution every cron's `agent` field already goes through
    # (Config.resolve_cron_agent/1) - "assistant" round-trips to its full handle.
    assert cron.agent == "default/assistant"
  end
end
