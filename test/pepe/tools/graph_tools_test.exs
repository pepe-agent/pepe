defmodule Pepe.Tools.GraphToolsTest do
  @moduledoc """
  The conversational surface of `Pepe.Graph`: `manage_graph` (define/inspect/remove,
  always scoped to the calling agent's own graphs), `run_graph` (execute, including the
  recursion guard - a graph cannot call `run_graph` on itself from inside its own run),
  and `inspect_graph_run` (read a run's status/history back). The execution loop itself
  is covered in `Pepe.Graph.RunnerTest`; this file only exercises the tool wrappers.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Graph
  alias Pepe.Tools.InspectGraphRun
  alias Pepe.Tools.ManageGraph
  alias Pepe.Tools.RunGraph

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_gtools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["read_file"]})
    {:ok, agent: Config.get_agent("writer")}
  end

  defp import_args(overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "import",
        "graph_name" => "reads",
        "entry" => "read",
        "nodes" => [%{"id" => "read", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "note.txt"}}]
      },
      overrides
    )
  end

  describe "manage_graph" do
    test "with no calling agent in ctx, every action refuses", %{agent: _} do
      assert ManageGraph.run(%{"action" => "list"}, %{}) == {:error, "no calling agent in context"}
      assert ManageGraph.run(%{"action" => "get", "graph_name" => "x"}, %{}) == {:error, "no calling agent in context"}
      assert ManageGraph.run(import_args(), %{}) == {:error, "no calling agent in context"}
      assert ManageGraph.run(%{"action" => "remove", "graph_name" => "x"}, %{}) == {:error, "no calling agent in context"}
    end

    test "an action-less call is refused with a clear message" do
      assert ManageGraph.run(%{}, %{agent: %{}}) == {:error, "manage_graph needs an `action` (and usually `graph_name`)"}
    end

    test "list is empty text before any graph exists, then shows one after import", %{agent: agent} do
      assert {:ok, "No graphs defined yet."} = ManageGraph.run(%{"action" => "list"}, %{agent: agent})
      assert {:ok, saved} = ManageGraph.run(import_args(), %{agent: agent})
      assert saved =~ "Saved graph reads"
      assert {:ok, listed} = ManageGraph.run(%{"action" => "list"}, %{agent: agent})
      assert listed =~ "reads (entry: read, 1 node(s))"
    end

    test "get describes an existing graph's nodes and entry", %{agent: agent} do
      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, out} = ManageGraph.run(%{"action" => "get", "graph_name" => "reads"}, %{agent: agent})
      assert out =~ "graph: reads"
      assert out =~ "entry: read"
      assert out =~ "read (tool) -> (terminal)"
    end

    test "get on a graph that doesn't exist errors by name", %{agent: agent} do
      assert ManageGraph.run(%{"action" => "get", "graph_name" => "ghost"}, %{agent: agent}) == {:error, "no graph named ghost"}
    end

    test "import always overwrites - calling it twice replaces rather than erroring", %{agent: agent} do
      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      changed = import_args(%{"nodes" => [%{"id" => "read", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "other.txt"}}]})
      assert {:ok, _} = ManageGraph.run(changed, %{agent: agent})
      assert Graph.get(agent.name, "reads")["nodes"] == changed["nodes"]
    end

    test "importing an invalid structure reports every problem, not just the first", %{agent: agent} do
      bad = import_args(%{"entry" => "ghost", "nodes" => [%{"id" => "read", "type" => "bogus"}]})
      assert {:error, message} = ManageGraph.run(bad, %{agent: agent})
      assert message =~ "Invalid graph:"
      assert message =~ "unknown entry node"
      assert message =~ "unknown type"
    end

    test "importing with an unauthorized cross-agent node reports that specifically", %{agent: agent} do
      Config.put_agent(%Agent{name: "other", system_prompt: "x"})
      bad = import_args(%{"nodes" => [%{"id" => "read", "type" => "agent", "agent" => "other", "prompt" => "x"}]})
      assert {:error, message} = ManageGraph.run(bad, %{agent: agent})
      assert message =~ "not allowed to address"
    end

    test "remove deletes; removing again errors by name", %{agent: agent} do
      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, "Removed graph reads."} = ManageGraph.run(%{"action" => "remove", "graph_name" => "reads"}, %{agent: agent})
      assert Graph.get(agent.name, "reads") == nil
      assert ManageGraph.run(%{"action" => "remove", "graph_name" => "reads"}, %{agent: agent}) == {:error, "no graph named reads"}
    end

    test "a graph is scoped to its owner - one agent cannot see or manage another's", %{agent: agent} do
      Config.put_agent(%Agent{name: "rival", system_prompt: "x", tools: ["read_file"]})
      rival = Config.get_agent("rival")

      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, "No graphs defined yet."} = ManageGraph.run(%{"action" => "list"}, %{agent: rival})
      assert ManageGraph.run(%{"action" => "get", "graph_name" => "reads"}, %{agent: rival}) == {:error, "no graph named reads"}
    end
  end

  describe "run_graph" do
    test "refuses to run from inside another graph run's own tool-call context" do
      assert RunGraph.run(%{"graph_name" => "anything"}, %{graph_run_id: "grun_abc123"}) ==
               {:error, "run_graph cannot be called from inside a graph run - use the matching node type in the graph itself instead"}
    end

    test "needs a graph_name" do
      assert RunGraph.run(%{}, %{agent: %{}}) == {:error, "run_graph needs a `graph_name`"}
    end

    test "with no calling agent in ctx, refuses" do
      assert RunGraph.run(%{"graph_name" => "x"}, %{}) == {:error, "no calling agent in context"}
    end

    test "an unknown graph name errors by name", %{agent: agent} do
      assert RunGraph.run(%{"graph_name" => "ghost"}, %{agent: agent}) == {:error, "no graph named ghost"}
    end

    test "a graph that finishes describes its final output", %{agent: agent} do
      dir = Pepe.Agent.Workspace.dir(agent.name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.txt"), "hello from disk")

      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, out} = RunGraph.run(%{"graph_name" => "reads"}, %{agent: agent})
      assert out =~ "done. Final output (read):"
      assert out =~ "hello from disk"
    end

    test "a graph that fails describes the error", %{agent: _agent} do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["bash"], auto_approve: []})
      agent = Config.get_agent("writer")
      denied = import_args(%{"nodes" => [%{"id" => "read", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]})
      assert {:ok, _} = ManageGraph.run(denied, %{agent: agent})

      assert {:ok, out} = RunGraph.run(%{"graph_name" => "reads"}, %{agent: agent})
      assert out =~ "run "
      assert out =~ "failed:"
      assert out =~ "not authorized"
    end

    test "a graph that pauses on a human node describes the run id and the question", %{agent: agent} do
      paused =
        import_args(%{
          "entry" => "review",
          "nodes" => [%{"id" => "review", "type" => "human", "ask" => "approve {{input}}?", "next" => "end"}]
        })

      assert {:ok, _} = ManageGraph.run(paused, %{agent: agent})
      assert {:ok, out} = RunGraph.run(%{"graph_name" => "reads", "input" => "this report"}, %{agent: agent})
      assert out =~ "waiting_human at node review"
      assert out =~ "approve this report?"
    end

    test "a tainted calling conversation seeds the run tainted_from_start - it cannot launder itself clean" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["bash"], auto_approve: ["bash:none"]})
      agent = Config.get_agent("writer")
      gated = import_args(%{"nodes" => [%{"id" => "read", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]})
      assert {:ok, _} = ManageGraph.run(gated, %{agent: agent})

      assert {:ok, out} = RunGraph.run(%{"graph_name" => "reads"}, %{agent: agent, tainted: true})
      assert out =~ "failed:"
      assert out =~ "not authorized"
    end

    test "an untainted calling conversation runs the same graph clean" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["bash"], auto_approve: ["bash:none"]})
      agent = Config.get_agent("writer")
      gated = import_args(%{"nodes" => [%{"id" => "read", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]})
      assert {:ok, _} = ManageGraph.run(gated, %{agent: agent})

      assert {:ok, out} = RunGraph.run(%{"graph_name" => "reads"}, %{agent: agent})
      assert out =~ "done."
    end

    test "run_graph's own output counts as outside content, the same as delegate/fetch_url" do
      assert Pepe.Agent.Runtime.outside_content?("run_graph")
    end
  end

  describe "inspect_graph_run" do
    test "needs a run_id" do
      assert InspectGraphRun.run(%{}, %{}) == {:error, "inspect_graph_run needs a `run_id`"}
    end

    test "with no calling agent in ctx, refuses" do
      assert InspectGraphRun.run(%{"run_id" => "grun_ghost"}, %{}) == {:error, "no calling agent in context"}
    end

    test "an unknown run id errors by id", %{agent: agent} do
      assert InspectGraphRun.run(%{"run_id" => "grun_ghost"}, %{agent: agent}) == {:error, "no run with id grun_ghost"}
    end

    test "an existing run shows status, current node, and history", %{agent: agent} do
      dir = Pepe.Agent.Workspace.dir(agent.name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.txt"), "hi")

      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, run} = Graph.run(agent.name, "reads", nil)

      assert {:ok, out} = InspectGraphRun.run(%{"run_id" => run["id"]}, %{agent: agent})
      assert out =~ "graph: reads"
      assert out =~ "status: done"
      assert out =~ "current_node: read"
      assert out =~ "read (visit 1) -> end"
    end

    test "a run belonging to a different agent is not visible - a run id alone isn't enough", %{agent: agent} do
      Config.put_agent(%Agent{name: "rival", system_prompt: "x", tools: ["read_file"]})
      rival = Config.get_agent("rival")

      dir = Pepe.Agent.Workspace.dir(agent.name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.txt"), "hi")

      assert {:ok, _} = ManageGraph.run(import_args(), %{agent: agent})
      assert {:ok, run} = Graph.run(agent.name, "reads", nil)

      assert InspectGraphRun.run(%{"run_id" => run["id"]}, %{agent: rival}) == {:error, "no run with id #{run["id"]}"}
    end
  end
end
