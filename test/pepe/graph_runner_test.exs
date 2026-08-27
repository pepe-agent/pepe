defmodule Pepe.Graph.RunnerTest do
  @moduledoc """
  `Pepe.Graph.Runner`'s execution loop end to end: the happy path, a verifier's
  loop-back (and the safety cap when it never converges), a bad verdict, a human node's
  pause/resume with atomic claim, hand-back landing only on a late (separate-turn)
  resume, per-key taint precision, a tool node's gate, and `{{ref|default:"..."}}`'s
  literal fallback. The recursion guard (`run_graph` cannot call itself) lives in
  `Pepe.Tools.RunGraphTest` instead, since it needs the tool wrapper, not just the
  runner.

  The mock model is a single script-driven plug: it reads the last user message (the
  node's own rendered prompt, since a graph node carries no history from any other
  node) and replies with whatever the test's script function says for that exact text -
  the same content-addressed scripting `Pepe.Permissions.PendingApprovalsTest`'s
  `TaintProbePlug` uses, generalized to arbitrary multi-node flows.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Graph
  alias Pepe.Watch.Delivery

  # Taint can't be observed by peeking at `Pepe.Permissions` from inside the mock HTTP
  # handler - that runs in Bandit's own process, not the run's. Instead this mirrors
  # `Pepe.Permissions.PendingApprovalsTest`'s `TaintProbePlug`: script a tool call for an
  # auto_approved tool and use whether it actually ran (a marker file) as the observable
  # proof of whether the turn that requested it started tainted.
  defmodule TaintProbePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      messages = req["messages"]
      last = List.last(messages)

      {message, finish_reason} =
        if last["role"] == "tool" do
          {%{"role" => "assistant", "content" => "done"}, "stop"}
        else
          user_prompt = messages |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.get("content")
          marker = Keyword.fetch!(opts, :marker_for).(user_prompt)

          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => "touch #{marker}"})}
          }

          {%{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}, "tool_calls"}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # Scripts a single tool call for "run_graph" naming the graph passed in `opts`, then a
  # plain finish once its tool result comes back - used to prove the recursion guard
  # fires for real, through the actual `graph_run_id` wiring, not just against a
  # hand-built ctx.
  defmodule RecursionProbePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      last = List.last(req["messages"])

      {message, finish_reason} =
        if last["role"] == "tool" do
          send(Keyword.fetch!(opts, :pid), {:tool_result, last["content"]})
          {%{"role" => "assistant", "content" => "done"}, "stop"}
        else
          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{
              "name" => "run_graph",
              "arguments" => Jason.encode!(%{"graph_name" => Keyword.fetch!(opts, :graph_name)})
            }
          }

          {%{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}, "tool_calls"}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  defmodule ScriptPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      prompt = req["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.get("content")
      reply = Keyword.fetch!(opts, :script).(prompt)
      message = %{"role" => "assistant", "content" => reply}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_grun_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)
    :ok
  end

  defp start_mock(script) do
    server = start_supervised!({Bandit, plug: {ScriptPlug, script: script}, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    model = "mock-#{System.unique_integer([:positive])}"
    Config.put_model(%Model{name: model, base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
    model
  end

  defp put_writer(model, extra \\ %{}) do
    Config.put_agent(
      struct(
        Agent,
        Map.merge(%{name: "writer", system_prompt: "x", model: model, tools: []}, extra)
      )
    )

    Config.get_agent("writer")
  end

  describe "happy path" do
    test "a two-node linear graph runs to completion and writes each node's reply to state" do
      model =
        start_mock(fn
          "draft " <> _ = _prompt -> "a fine draft"
          "publish: " <> _ -> "PUBLISHED: a fine draft"
        end)

      put_writer(model)

      definition = %{
        "name" => "linear",
        "agent" => "writer",
        "entry" => "draft",
        "nodes" => [
          %{"id" => "draft", "type" => "agent", "prompt" => "draft {{input}}", "next" => "publish"},
          %{"id" => "publish", "type" => "agent", "prompt" => "publish: {{draft}}"}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "linear", "widgets")

      assert run["status"] == "done"
      assert run["state"]["draft"] == "a fine draft"
      assert run["state"]["publish"] == "PUBLISHED: a fine draft"
      assert run["current_node"] == "publish"
      assert run["steps_taken"] == 2
      assert [%{"node" => "draft"}, %{"node" => "publish"}] = run["history"]
    end
  end

  describe "verifier loop-back" do
    test "a rejected draft loops back, the critique reaches the second attempt, then passes" do
      model =
        start_mock(fn
          "draft: widgets. critique: (none yet)" -> "draft one"
          "draft: widgets. critique: not enough detail.\nfail" -> "draft two, now detailed"
          "check: draft one" -> "not enough detail.\nfail"
          "check: draft two, now detailed" -> "much better.\npass"
        end)

      put_writer(model)

      definition = %{
        "name" => "revise",
        "agent" => "writer",
        "entry" => "draft",
        "nodes" => [
          %{
            "id" => "draft",
            "type" => "agent",
            "prompt" => "draft: {{input}}. critique: {{verify?}}",
            "next" => "verify"
          },
          %{
            "id" => "verify",
            "type" => "verifier",
            "prompt" => "check: {{draft}}",
            "verdicts" => %{"pass" => "end", "fail" => "draft"}
          }
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "revise", "widgets")

      assert run["status"] == "done"
      assert run["state"]["draft"] == "draft two, now detailed"
      assert run["visits"] == %{"draft" => 2, "verify" => 2}
      assert run["steps_taken"] == 4

      [h1, h2, h3, h4] = run["history"]
      assert h1["node"] == "draft" and h1["visit"] == 1
      assert h2["node"] == "verify" and h2["visit"] == 1 and h2["verdict"] == "fail"
      assert h3["node"] == "draft" and h3["visit"] == 2
      assert h4["node"] == "verify" and h4["visit"] == 2 and h4["verdict"] == "pass"
    end

    test "a verifier that never converges terminates at the step cap, never spins forever" do
      model = start_mock(fn _prompt -> "still not good enough.\nfail" end)
      put_writer(model)

      definition = %{
        "name" => "never-passes",
        "agent" => "writer",
        "entry" => "draft",
        "max_steps" => 4,
        "nodes" => [
          %{"id" => "draft", "type" => "agent", "prompt" => "draft {{input}}", "next" => "verify"},
          %{"id" => "verify", "type" => "verifier", "prompt" => "check {{draft}}", "verdicts" => %{"pass" => "end", "fail" => "draft"}}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "never-passes", "widgets")

      assert run["status"] == "failed"
      assert run["steps_taken"] == 4
      assert run["error"] =~ "step budget exhausted"
    end

    test "a reply whose last line matches no verdict fails the run cleanly" do
      model = start_mock(fn _prompt -> "I genuinely have no idea" end)
      put_writer(model)

      definition = %{
        "name" => "bad-verdict",
        "agent" => "writer",
        "entry" => "verify",
        "nodes" => [
          %{"id" => "verify", "type" => "verifier", "prompt" => "check {{input}}", "verdicts" => %{"pass" => "end", "fail" => "verify"}}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "bad-verdict", "x")

      assert run["status"] == "failed"
      assert run["error"] =~ "matches no verdict"
    end
  end

  describe "human node: pause and resume" do
    test "a human node pauses without calling the model, and the reply feeds the next node" do
      model = start_mock(fn _prompt -> flunk("the model must not be called for a human node") end)
      put_writer(model)

      definition = %{
        "name" => "with-human",
        "agent" => "writer",
        "entry" => "review",
        "nodes" => [
          %{"id" => "review", "type" => "human", "ask" => "approve {{input}}?", "next" => "done"},
          %{"id" => "done", "type" => "agent", "prompt" => "human said: {{review}}"}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "with-human", "the report")

      assert run["status"] == "waiting_human"
      assert run["current_node"] == "review"
      assert [%{"node" => "review", "asked" => "approve the report?"}] = run["history"]

      # Swap in a real model only now, for the node that runs after resume.
      Config.put_model(%Model{
        name: "after-resume",
        base_url: Config.get_model(model).base_url,
        api_key: "k",
        model: "m"
      })

      resumable_model =
        start_mock(fn "human said: yes, ship it" -> "final: yes, ship it" end)

      Config.put_agent(%Agent{name: "writer", system_prompt: "x", model: resumable_model, tools: []})

      assert {:ok, resumed} = Graph.resume(run["id"], "yes, ship it")
      assert resumed["status"] == "done"
      assert resumed["state"]["review"] == "yes, ship it"
      assert resumed["state"]["done"] == "final: yes, ship it"
    end

    test "resume is atomic - N concurrent resolvers on the same waiting run have exactly one winner" do
      model = start_mock(fn _prompt -> "ok" end)
      put_writer(model)

      definition = %{
        "name" => "race",
        "agent" => "writer",
        "entry" => "review",
        "nodes" => [%{"id" => "review", "type" => "human", "ask" => "ok?", "next" => "end"}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "race", nil)
      assert run["status"] == "waiting_human"

      results =
        1..8
        |> Enum.map(fn i -> Task.async(fn -> Graph.resume(run["id"], "answer-#{i}") end) end)
        |> Task.await_many(60_000)

      assert Enum.count(results, &match?({:ok, %{"status" => "done"}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:already, "running"}}, &1)) == 7

      final = Graph.get_run(run["id"])
      assert final["status"] == "done"
      assert String.starts_with?(final["state"]["review"], "answer-")
    end

    test "hand-back only fires on a resume that finishes the run, never on the synchronous start turn" do
      server_pid = self()

      model =
        start_mock(fn
          "[Graph update" <> _ = prompt -> send(server_pid, {:model_saw_handback_note, prompt}) && "noted"
        end)

      put_writer(model)

      definition = %{
        "name" => "handback",
        "agent" => "writer",
        "entry" => "review",
        "nodes" => [%{"id" => "review", "type" => "human", "ask" => "review this", "next" => "end"}]
      }

      assert {:ok, _} = Graph.import(definition)

      key = "ws:graph-handback-#{System.unique_integer([:positive])}"
      origin = %{"channel" => "ws", "key" => key}
      {:ok, _} = Registry.register(Pepe.Watch.Subscribers, Delivery.topic(origin), nil)
      Phoenix.PubSub.subscribe(Pepe.PubSub, Delivery.topic(origin))

      assert {:ok, run} = Graph.run("writer", "handback", nil, session_key: key, origin: origin)
      assert run["status"] == "waiting_human"
      refute_received {:model_saw_handback_note, _}

      assert {:ok, resumed} = Graph.resume(run["id"], "approved")
      assert resumed["status"] == "done"

      assert_receive {:model_saw_handback_note, note}, 2_000
      assert note =~ "finished"
      assert_receive {:watch_message, ^origin, "noted"}, 2_000
    end
  end

  describe "parallel node is gated, not called unguarded" do
    test "delegate must still be authorized (auto_approve) at run time, not just importable" do
      # `delegate` requires approval like any other tool: having it in `tools` is enough to
      # pass import, but the live `Permissions.gate/3` call this node makes still refuses
      # without `auto_approve` covering it - proving `Tools.execute/2` is never reached
      # unguarded.
      put_writer("unused", %{tools: ["delegate"], auto_approve: []})

      definition = %{
        "name" => "fanout-denied",
        "agent" => "writer",
        "entry" => "research",
        "nodes" => [%{"id" => "research", "type" => "parallel", "agent" => "writer", "tasks" => ["look things up"]}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "fanout-denied", nil)

      assert run["status"] == "failed"
      assert run["error"] =~ "not authorized"
    end

    test "an agent granted delegate fans out for real and the combined answer lands in state" do
      model =
        start_mock(fn _prompt -> "worker answer" end)

      put_writer(model, %{tools: ["delegate"], auto_approve: ["delegate:none"]})

      definition = %{
        "name" => "fanout-allowed",
        "agent" => "writer",
        "entry" => "research",
        "nodes" => [%{"id" => "research", "type" => "parallel", "agent" => "writer", "tasks" => ["look things up"]}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "fanout-allowed", nil)

      assert run["status"] == "done"
      assert run["state"]["research"] =~ "worker answer"
    end
  end

  describe "tool node" do
    test "an always-safe tool call inside the workspace runs and writes its result to state" do
      model = start_mock(fn _prompt -> flunk("no model call needed for a tool node") end)
      agent = put_writer(model, %{tools: ["read_file"]})
      dir = Pepe.Agent.Workspace.dir(agent.name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.txt"), "hello from disk")

      definition = %{
        "name" => "reads",
        "agent" => "writer",
        "entry" => "read",
        "nodes" => [%{"id" => "read", "type" => "tool", "tool" => "read_file", "args" => %{"path" => "note.txt"}}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "reads", nil)

      assert run["status"] == "done"
      assert run["state"]["read"] =~ "hello from disk"
    end

    test "a tool call the gate refuses fails the run instead of parking or bypassing" do
      model = start_mock(fn _prompt -> flunk("no model call needed for a tool node") end)
      put_writer(model, %{tools: ["bash"], auto_approve: []})

      definition = %{
        "name" => "denied",
        "agent" => "writer",
        "entry" => "run",
        "nodes" => [%{"id" => "run", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "denied", nil)

      assert run["status"] == "failed"
      assert run["error"] =~ "not authorized"
    end
  end

  describe "per-key taint" do
    test "only a node that actually references the tainted key runs untrusted: true" do
      clean_marker = Path.join(System.tmp_dir!(), "pepe_graph_clean_#{System.unique_integer([:positive])}")
      dirty_marker = Path.join(System.tmp_dir!(), "pepe_graph_dirty_#{System.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(clean_marker)
        File.rm(dirty_marker)
      end)

      marker_for = fn
        "clean: " <> _ -> clean_marker
        "dirty: " <> _ -> dirty_marker
      end

      server = start_supervised!({Bandit, plug: {TaintProbePlug, marker_for: marker_for}, port: 0, scheme: :http})
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      model = "taint-#{System.unique_integer([:positive])}"
      Config.put_model(%Model{name: model, base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
      put_writer(model, %{tools: ["fetch_url", "bash"], auto_approve: ["bash:none"]})

      definition = %{
        "name" => "taint",
        "agent" => "writer",
        "entry" => "fetch",
        "state" => %{"topic" => "widgets"},
        "nodes" => [
          # Nothing listens on port 1 - the fetch itself fails fast, but tainting a tool
          # node's output key must not depend on the call succeeding (same rule the normal
          # turn loop's `Runtime.taint_if_outside/1` follows: the tool NAME is what matters).
          %{"id" => "fetch", "type" => "tool", "tool" => "fetch_url", "args" => %{"url" => "http://127.0.0.1:1/"}, "next" => "clean"},
          %{"id" => "clean", "type" => "agent", "prompt" => "clean: {{topic}}", "next" => "dirty"},
          %{"id" => "dirty", "type" => "agent", "prompt" => "dirty: {{fetch}}"}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "taint", nil)

      assert run["status"] == "done"
      # `dirty` itself joins `tainted_keys` too: its own turn ran tainted (it read `fetch`),
      # so its output must propagate the taint to whoever reads `dirty` next.
      assert Enum.sort(run["tainted_keys"]) == ["dirty", "fetch"]

      # `clean` only reads `topic` (never tainted): its turn starts untrusted, so the
      # auto_approved `bash` call it requests actually runs. `dirty` reads `fetch` directly:
      # its turn starts tainted, auto_approve is withdrawn for it, and the same kind of
      # call is refused instead - the only way to observe `untrusted:` from outside.
      assert File.exists?(clean_marker), "clean's auto-approved call should have run untainted"
      refute File.exists?(dirty_marker), "dirty's auto-approved call must be refused - its turn started tainted"
    end
  end

  describe "{{ref|default:\"...\"}}" do
    test "a missing key uses the literal; a bound key overrides it" do
      model =
        start_mock(fn
          "topic: widgets" -> "used the real topic"
        end)

      put_writer(model)

      definition = %{
        "name" => "default-ref",
        "agent" => "writer",
        "entry" => "step",
        "state" => %{"topic" => "widgets"},
        "nodes" => [%{"id" => "step", "type" => "agent", "prompt" => "topic: {{topic|default:\"fallback-topic\"}}"}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "default-ref", nil)
      assert run["status"] == "done"
      assert run["state"]["step"] == "used the real topic"
    end

    test "a required {{ref}} with no default and no state fails the run instead of sending a half prompt" do
      model = start_mock(fn _prompt -> flunk("must never reach the model with an unbound ref") end)
      put_writer(model)

      definition = %{
        "name" => "unbound",
        "agent" => "writer",
        "entry" => "step",
        "nodes" => [
          %{"id" => "other", "type" => "agent", "prompt" => "x"},
          %{"id" => "step", "type" => "agent", "prompt" => "needs: {{other}}"}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "unbound", nil)
      assert run["status"] == "failed"
      assert run["error"] =~ "unbound reference"
    end
  end

  describe "taint does not leak past the node that earned it" do
    test "a clean tool node right after a tainted one still runs trusted" do
      # `fetch` taints (nothing listens on port 1, but tainting a tool node's output never
      # depends on the call succeeding). `next` reads no state at all - `node_tainted?` for
      # it is false - so it must run untainted. Before the fix, `with_taint_seed`'s restore
      # only fired once the WHOLE rest of the graph finished recursing, so `fetch`'s taint
      # stayed live in the process for every node downstream, and this node's auto_approved
      # `bash` call was wrongly refused.
      put_writer("unused", %{tools: ["fetch_url", "bash"], auto_approve: ["bash:none"]})

      definition = %{
        "name" => "no-leak",
        "agent" => "writer",
        "entry" => "fetch",
        "nodes" => [
          %{"id" => "fetch", "type" => "tool", "tool" => "fetch_url", "args" => %{"url" => "http://127.0.0.1:1/"}, "next" => "next"},
          %{"id" => "next", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}
        ]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "no-leak", nil)

      assert run["status"] == "done"
      assert run["tainted_keys"] == ["fetch"]
    end
  end

  describe "tainted_from_start (a tainted caller must not launder clean by starting a run)" do
    test "opts[:untrusted]: true taints every node, regardless of what it reads" do
      put_writer("unused", %{tools: ["bash"], auto_approve: ["bash:none"]})

      definition = %{
        "name" => "seeded",
        "agent" => "writer",
        "entry" => "run",
        "nodes" => [%{"id" => "run", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "seeded", nil, untrusted: true)

      assert run["status"] == "failed"
      assert run["error"] =~ "not authorized"
      assert Graph.get_run(run["id"])["tainted_from_start"] == true
    end

    test "without the seed, the same graph runs clean" do
      put_writer("unused", %{tools: ["bash"], auto_approve: ["bash:none"]})

      definition = %{
        "name" => "unseeded",
        "agent" => "writer",
        "entry" => "run",
        "nodes" => [%{"id" => "run", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "unseeded", nil)

      assert run["status"] == "done"
      assert Graph.get_run(run["id"])["tainted_from_start"] == false
    end
  end

  describe "authorization is re-checked live, not just at Pepe.Graph.import/2 time" do
    test "a tool later withdrawn from the agent's own tools list refuses instead of still running" do
      put_writer("unused", %{tools: ["bash"], auto_approve: ["bash:none"]})

      definition = %{
        "name" => "revoked-tool",
        "agent" => "writer",
        "entry" => "run",
        "nodes" => [%{"id" => "run", "type" => "tool", "tool" => "bash", "args" => %{"command" => "echo hi"}}]
      }

      assert {:ok, _} = Graph.import(definition)

      # The tool is withdrawn from the agent AFTER the graph was validated and saved.
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", tools: [], auto_approve: []})

      assert {:ok, run} = Graph.run("writer", "revoked-tool", nil)
      assert run["status"] == "failed"
      assert run["error"] =~ "not available"
    end

    test "a cross-agent node whose can_message was revoked refuses instead of still addressing them" do
      Config.put_agent(%Agent{name: "helper", system_prompt: "x"})
      helper_name = Config.get_agent("helper").name
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", can_message: [helper_name]})

      definition = %{
        "name" => "revoked-can-message",
        "agent" => "writer",
        "entry" => "ask",
        "nodes" => [%{"id" => "ask", "type" => "agent", "agent" => "helper", "prompt" => "x"}]
      }

      assert {:ok, _} = Graph.import(definition)

      # can_message is revoked AFTER the graph was validated and saved.
      Config.put_agent(%Agent{name: "writer", system_prompt: "x", can_message: []})

      assert {:ok, run} = Graph.run("writer", "revoked-can-message", nil)
      assert run["status"] == "failed"
      assert run["error"] =~ "not available"
    end
  end

  describe "a tool node's cwd" do
    test "runs inside the agent's own workspace, never the operator's own cwd" do
      agent = put_writer("unused", %{tools: ["bash"], auto_approve: ["bash:none"]})
      dir = Workspace.dir(agent.name)
      File.mkdir_p!(dir)
      marker = "graph_cwd_marker_#{System.unique_integer([:positive])}.txt"
      on_exit(fn -> File.rm(Path.join(File.cwd!(), marker)) end)

      definition = %{
        "name" => "cwdcheck",
        "agent" => "writer",
        "entry" => "touch",
        "nodes" => [%{"id" => "touch", "type" => "tool", "tool" => "bash", "args" => %{"command" => "touch #{marker}"}}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", "cwdcheck", nil)

      assert run["status"] == "done"
      assert File.exists?(Path.join(dir, marker)), "the tool node's bash call must run inside the agent's own workspace"
      refute File.exists?(Path.join(File.cwd!(), marker)), "must not run in the operator's own cwd"
    end
  end

  describe "run_graph cannot call itself, even for real, through the actual wiring" do
    test "graph_run_id reaches the model turn - the guard fires instead of recursing" do
      test_pid = self()
      graph_name = "loopy"

      server = start_supervised!({Bandit, plug: {RecursionProbePlug, pid: test_pid, graph_name: graph_name}, port: 0, scheme: :http})
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      model = "recursion-#{System.unique_integer([:positive])}"
      Config.put_model(%Model{name: model, base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
      put_writer(model, %{tools: ["run_graph"], auto_approve: ["run_graph:any"]})

      definition = %{
        "name" => graph_name,
        "agent" => "writer",
        "entry" => "start",
        "nodes" => [%{"id" => "start", "type" => "agent", "prompt" => "go"}]
      }

      assert {:ok, _} = Graph.import(definition)
      assert {:ok, run} = Graph.run("writer", graph_name, nil)

      assert run["status"] == "done"
      assert_receive {:tool_result, content}, 2_000
      assert content =~ "cannot be called from inside a graph run"
    end
  end
end
