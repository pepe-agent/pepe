defmodule Pepe.GraphTest do
  @moduledoc """
  `Pepe.Graph`'s durable-definition half: `import/2`'s validation (every failure mode a
  bad definition can hit, reported all at once, not just the first) and the plain CRUD
  around it. `Pepe.Graph.Runner`'s execution loop is covered separately in
  `Pepe.Graph.RunnerTest`, since that needs a mock model.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Graph

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_graph_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: []})
    Config.put_agent(%Agent{name: "checker", system_prompt: "x", tools: [], can_message: []})
    :ok
  end

  defp linear_def(name \\ "linear") do
    %{
      "name" => name,
      "agent" => "writer",
      "entry" => "draft",
      "nodes" => [
        %{"id" => "draft", "type" => "agent", "prompt" => "write about {{input}}"}
      ]
    }
  end

  describe "import/2 - happy paths" do
    test "a minimal one-node graph imports and round-trips through get/2" do
      assert {:ok, saved} = Graph.import(linear_def())
      assert saved["name"] == "linear"
      assert saved["agent"] == Config.get_agent("writer").name
      assert saved["max_steps"] == 25
      assert Graph.get("writer", "linear") == saved
    end

    test "a bare agent handle resolves the same as the canonical name" do
      assert {:ok, saved} = Graph.import(linear_def())
      assert Graph.get("writer", "linear")["agent"] == saved["agent"]
    end

    test "importing twice without overwrite refuses; overwrite: true replaces" do
      assert {:ok, _} = Graph.import(linear_def())
      assert Graph.import(linear_def()) == {:error, :already_exists}

      changed = put_in(linear_def()["nodes"], [%{"id" => "draft", "type" => "agent", "prompt" => "changed: {{input}}"}])
      assert {:ok, saved} = Graph.import(changed, overwrite: true)
      assert [%{"prompt" => "changed: {{input}}"}] = saved["nodes"]
    end

    test "max_steps is clamped to 1..100" do
      assert {:ok, saved} = Graph.import(Map.put(linear_def("a"), "max_steps", 500))
      assert saved["max_steps"] == 100
      assert {:ok, saved} = Graph.import(Map.put(linear_def("b"), "max_steps", 0))
      assert saved["max_steps"] == 1
    end

    test "a verifier that loops back to an earlier node is valid" do
      definition = %{
        "name" => "loop",
        "agent" => "writer",
        "entry" => "draft",
        "nodes" => [
          %{"id" => "draft", "type" => "agent", "prompt" => "draft {{input}}, critique {{verify?}}", "next" => "verify"},
          %{"id" => "verify", "type" => "verifier", "prompt" => "check {{draft}}", "verdicts" => %{"pass" => "end", "fail" => "draft"}}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
    end

    test "a human node with a static next is valid" do
      definition = %{
        "name" => "ask",
        "agent" => "writer",
        "entry" => "review",
        "nodes" => [%{"id" => "review", "type" => "human", "ask" => "ok? {{input}}", "next" => "end"}]
      }

      assert {:ok, _} = Graph.import(definition)
    end

    test "a parallel node with tasks and a known agent is valid" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["delegate"]})

      definition = %{
        "name" => "fanout",
        "agent" => "writer",
        "entry" => "research",
        "nodes" => [%{"id" => "research", "type" => "parallel", "agent" => "writer", "tasks" => ["look up {{input}}"]}]
      }

      assert {:ok, _} = Graph.import(definition)
    end

    test "a tool node naming a known, non-denied tool the owner is allowed to use is valid" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["read_file"]})

      definition = %{
        "name" => "fetch",
        "agent" => "writer",
        "entry" => "read",
        "nodes" => [%{"id" => "read", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "{{input}}"}}]
      }

      assert {:ok, _} = Graph.import(definition)
    end
  end

  describe "import/2 - rejects an unknown owning agent" do
    test "no such agent" do
      assert Graph.import(Map.put(linear_def(), "agent", "ghost")) ==
               {:error, {:invalid, ["unknown agent \"ghost\""]}}
    end
  end

  describe "import/2 - structural validation" do
    test "no nodes at all" do
      assert {:error, {:invalid, errors}} = Graph.import(Map.put(linear_def(), "nodes", []))
      assert "a graph needs at least one node" in errors
    end

    test "a node that isn't a JSON object is refused instead of crashing on & &1[\"id\"]" do
      definition = Map.put(linear_def(), "nodes", ["not a node object"])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert "every node must be a JSON object" in errors
    end

    test "a definition that isn't a JSON object is refused instead of crashing on definition[\"agent\"]" do
      assert Graph.import("just a string") == {:error, {:invalid, ["the graph definition must be a JSON object"]}}
      assert Graph.import(["a", "list"]) == {:error, {:invalid, ["the graph definition must be a JSON object"]}}
      assert Graph.import(42) == {:error, {:invalid, ["the graph definition must be a JSON object"]}}
    end

    test "duplicate node ids" do
      definition =
        Map.put(linear_def(), "nodes", [
          %{"id" => "a", "type" => "agent", "prompt" => "x", "next" => "end"},
          %{"id" => "a", "type" => "agent", "prompt" => "y"}
        ])
        |> Map.put("entry", "a")

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "duplicate node id"))
    end

    test "a reserved node id (end/input) is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "end", "type" => "agent", "prompt" => "x"}]) |> Map.put("entry", "end")
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "reserved"))
    end

    test "an id with invalid characters is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "Bad Id!", "type" => "agent", "prompt" => "x"}]) |> Map.put("entry", "Bad Id!")
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "must match"))
    end

    test "entry pointing to a node that doesn't exist" do
      assert {:error, {:invalid, errors}} = Graph.import(Map.put(linear_def(), "entry", "ghost"))
      assert Enum.any?(errors, &(&1 =~ "unknown entry node"))
    end

    test "next pointing at a node that doesn't exist" do
      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "prompt" => "x", "next" => "ghost"}])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "unknown target"))
    end

    test "a verdict target pointing at a node that doesn't exist" do
      definition =
        Map.put(linear_def(), "nodes", [
          %{"id" => "draft", "type" => "verifier", "prompt" => "x", "verdicts" => %{"pass" => "ghost"}}
        ])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "unknown target"))
    end

    test "a {{ref}} naming a node id that doesn't exist" do
      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "prompt" => "{{ghost}} and {{input}}"}])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "references no node"))
    end

    test "a {{ref}} inside a tool node's args is checked too" do
      definition =
        Map.put(linear_def(), "nodes", [
          %{"id" => "draft", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "{{ghost}}"}}
        ])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "references no node"))
    end

    test "reports every problem at once, not just the first" do
      definition =
        linear_def()
        |> Map.put("entry", "ghost-entry")
        |> Map.put("nodes", [%{"id" => "draft", "type" => "agent", "prompt" => "{{ghost-ref}}", "next" => "ghost-next"}])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.count_until(errors, 3) >= 3
    end
  end

  describe "import/2 - per-node-type validation" do
    test "an agent node cannot carry verdicts" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "prompt" => "x", "verdicts" => %{"a" => "end"}}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "cannot have verdicts"))
    end

    test "a verifier node needs non-empty verdicts" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "verifier", "prompt" => "x"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "needs non-empty verdicts"))
    end

    test "a verifier node cannot also carry next" do
      definition =
        Map.put(linear_def(), "nodes", [
          %{"id" => "draft", "type" => "verifier", "prompt" => "x", "verdicts" => %{"a" => "end"}, "next" => "end"}
        ])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "cannot have next"))
    end

    test "a human node cannot carry verdicts" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "human", "ask" => "x", "verdicts" => %{"a" => "end"}}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "cannot have verdicts"))
    end

    test "a parallel node needs a non-empty tasks list" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "parallel", "agent" => "writer", "tasks" => []}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "needs a non-empty tasks list"))
    end

    test "a parallel node needs a known agent" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "parallel", "agent" => "ghost", "tasks" => ["x"]}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "parallel needs a known agent"))
    end

    test "a parallel node's tasks must all be strings" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "parallel", "agent" => "writer", "tasks" => ["x", 5]}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "every task must be a string"))
    end

    test "a parallel node naming an agent never granted delegate is refused" do
      # Nothing else on this path checks the resolved agent's tools allowlist before
      # fanning out via `delegate` - a graph node names it directly, no model choosing
      # from an offered list involved.
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "parallel", "agent" => "writer", "tasks" => ["x"]}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "not allowed to use delegate"))
    end

    test "a tool node naming a tool the executing agent was never granted is refused" do
      # `writer` (set up with `tools: []`) has no `read_file` - a graph node calls its
      # tool directly, with no model choosing from an offered list, so nothing else on
      # this path would otherwise catch an agent reaching a tool it was never given.
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "tool", "tool" => "read_file"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "not allowed to use"))
    end

    test "a tool node naming an unknown tool is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "tool", "tool" => "not_a_real_tool"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "unknown tool"))
    end

    test "a tool node's args must be a JSON object, not a crash waiting to happen at render time" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["read_file"]})

      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "tool", "tool" => "read_file", "args" => ["not", "a", "map"]}])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "args must be a JSON object"))
    end

    test "a tool node cannot name run_code, delegate, or run_graph directly" do
      for denied <- ~w(run_code delegate run_graph) do
        definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "tool", "tool" => denied}])
        assert {:error, {:invalid, errors}} = Graph.import(definition)
        assert Enum.any?(errors, &(&1 =~ "use the #{denied} node type"))
      end
    end

    test "an unknown node type is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "bogus"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "unknown type"))
    end
  end

  describe "import/2 - required fields per node type" do
    test "an agent node with no prompt is refused, not left to crash at run time" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "needs a \"prompt\""))
    end

    test "a verifier node with no prompt is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "verifier", "verdicts" => %{"pass" => "end"}}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "needs a \"prompt\""))
    end

    test "a human node with no ask is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "human"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "needs an \"ask\""))
    end

    test "a graph with no name is refused rather than crashing the insert on a NOT NULL column" do
      assert {:error, {:invalid, errors}} = Graph.import(Map.delete(linear_def(), "name"))
      assert Enum.any?(errors, &(&1 =~ "needs a non-empty \"name\""))
    end

    test "a graph with a blank name is refused" do
      assert {:error, {:invalid, errors}} = Graph.import(Map.put(linear_def(), "name", ""))
      assert Enum.any?(errors, &(&1 =~ "needs a non-empty \"name\""))
    end
  end

  describe "import/2 - verdict keys must already be lowercase" do
    test "an uppercase verdict key is refused - Prompt.verdict/2 lowercases the reply before matching" do
      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "verifier", "prompt" => "x", "verdicts" => %{"PASS" => "end"}}])

      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "must be lowercase"))
    end

    test "a lowercase verdict key is fine" do
      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "verifier", "prompt" => "x", "verdicts" => %{"pass" => "end"}}])

      assert {:ok, _} = Graph.import(definition)
    end
  end

  describe "import/2 - the can_message boundary" do
    test "a node naming a different agent the owner may not address is refused" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "agent" => "checker", "prompt" => "x"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "not allowed to address" and &1 =~ "checker"))
    end

    test "a node naming an agent that doesn't exist at all is refused with a clear reason" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "agent" => "ghost", "prompt" => "x"}])
      assert {:error, {:invalid, errors}} = Graph.import(definition)
      assert Enum.any?(errors, &(&1 =~ "unknown agent"))
    end

    test "a node naming a different agent the owner IS allowed to message is fine" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: [], can_message: [Config.get_agent("checker").name]})
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "agent" => "checker", "prompt" => "x"}])
      assert {:ok, _} = Graph.import(definition)
    end

    test "a node naming the owner itself needs no can_message entry" do
      definition = Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "agent", "agent" => "writer", "prompt" => "x"}])
      assert {:ok, _} = Graph.import(definition)
    end
  end

  describe "CRUD" do
    test "for_agent/1 lists a given agent's graphs sorted by name" do
      assert {:ok, _} = Graph.import(linear_def("b-graph"))
      assert {:ok, _} = Graph.import(linear_def("a-graph"))
      assert Enum.map(Graph.for_agent("writer"), & &1["name"]) == ["a-graph", "b-graph"]
    end

    test "for_agent/1 for an agent with no graphs is empty" do
      assert Graph.for_agent("writer") == []
    end

    test "for_agent/1 for an unknown agent is empty, not an error" do
      assert Graph.for_agent("ghost") == []
    end

    test "get/2 for a missing graph is nil" do
      assert Graph.get("writer", "ghost") == nil
    end

    test "delete/2 removes the definition; a missing one errors" do
      assert {:ok, _} = Graph.import(linear_def())
      assert Graph.delete("writer", "linear") == :ok
      assert Graph.get("writer", "linear") == nil
      assert Graph.delete("writer", "linear") == {:error, :not_found}
    end
  end

  describe "run/4 against an unknown graph" do
    test "returns :not_found without touching the runner" do
      assert Graph.run("writer", "ghost", "hi") == {:error, :not_found}
    end
  end

  describe "runs/1 scoping" do
    test "an unknown --agent scopes to nothing, never to every agent's runs" do
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: ["read_file"]})
      writer = Config.get_agent("writer")
      dir = Pepe.Agent.Workspace.dir(writer.name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.txt"), "hi")

      definition =
        Map.put(linear_def(), "nodes", [%{"id" => "draft", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "note.txt"}}])

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, _run} = Graph.run("writer", "linear", nil)

      assert Graph.runs(agent: "totally-not-a-real-agent") == []
      assert [_one] = Graph.runs(agent: "writer")
      assert [_one] = Graph.runs()
    end
  end

  describe "resume/2 and get_run/1 against an unknown run" do
    test "resume of a missing run id" do
      assert Graph.resume("grun_ghost", "yes") == {:error, :not_found}
    end

    test "get_run of a missing run id" do
      assert Graph.get_run("grun_ghost") == nil
    end
  end

  describe "stale?/1" do
    test "a running/waiting_human run older than 15 minutes is stale" do
      old = System.system_time(:second) - 16 * 60
      assert Graph.stale?(%{"status" => "running", "updated_at" => old})
      assert Graph.stale?(%{"status" => "waiting_human", "updated_at" => old})
    end

    test "a recent run is not stale" do
      recent = System.system_time(:second) - 60
      refute Graph.stale?(%{"status" => "running", "updated_at" => recent})
    end

    test "a done/failed run is never flagged stale regardless of age" do
      old = System.system_time(:second) - 60 * 60
      refute Graph.stale?(%{"status" => "done", "updated_at" => old})
      refute Graph.stale?(%{"status" => "failed", "updated_at" => old})
    end
  end
end
