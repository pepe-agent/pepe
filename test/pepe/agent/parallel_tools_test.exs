defmodule Pepe.Agent.ParallelToolsTest do
  @moduledoc """
  The runtime runs the tool calls a model asked for together when it safely can.

  The tests here are about the three things that must survive it. Each of them would have
  broken quietly, which is why they are pinned: a silent wrong answer is worse than the
  serial version that was merely slow.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Answers one tool-calling turn: hand back the calls the test asked for, then a final
  # answer once their results come back.
  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      msgs = body |> Jason.decode!() |> Map.fetch!("messages")

      message =
        if Enum.any?(msgs, &(&1["role"] == "tool")) do
          %{"role" => "assistant", "content" => "done"}
        else
          %{"role" => "assistant", "content" => nil, "tool_calls" => Elixir.Agent.get(:pt_calls, & &1)}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_pt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :pt_calls)
    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    agent = %Agent{
      name: "worker",
      model: "mock",
      system_prompt: "hi",
      tools: ["read_file", "write_file", "fetch_url", "list_dir"],
      auto_approve: ["*"],
      max_iterations: 3
    }

    Config.put_agent(agent)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent, cwd: home, home: home}
  end

  defp call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  defp asks(calls), do: Elixir.Agent.update(:pt_calls, fn _ -> calls end)

  defp converse(agent, cwd, opts \\ []) do
    Runtime.converse(agent, "go", Keyword.merge([cwd: cwd], opts))
  end

  # The tools resolve a relative path against the agent's workspace, not against `cwd`, so
  # that is where a fixture has to land for the agent to see it.
  defp workspace(name) do
    dir = Pepe.Agent.Workspace.dir(name)
    File.mkdir_p!(dir)
    dir
  end

  # The tool results the model got back, in the order it got them.
  defp tool_results(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Enum.map(&{&1["tool_call_id"], &1["content"]})
  end

  describe "order" do
    test "results come back in the order the model asked, not the order they finished",
         %{agent: agent, cwd: cwd} do
      ws = workspace(agent.name)
      for n <- 1..3, do: File.write!(Path.join(ws, "f#{n}.txt"), "content-#{n}")

      asks([
        call("a", "read_file", %{"path" => "f1.txt"}),
        call("b", "read_file", %{"path" => "f2.txt"}),
        call("c", "read_file", %{"path" => "f3.txt"})
      ])

      {:ok, _reply, messages} = converse(agent, cwd)

      # The protocol pairs each result to its tool_call_id, so a shuffle would not lose an
      # answer, it would just make the transcript unreadable. Keep it readable.
      assert [{"a", one}, {"b", two}, {"c", three}] = tool_results(messages)
      assert one =~ "content-1"
      assert two =~ "content-2"
      assert three =~ "content-3"
    end

    test "a write between two reads is a barrier, so a read-after-write really reads after it",
         %{agent: agent, cwd: cwd} do
      ws = workspace(agent.name)
      File.write!(Path.join(ws, "seq.txt"), "before")

      asks([
        call("a", "read_file", %{"path" => "seq.txt"}),
        call("b", "write_file", %{"path" => "seq.txt", "content" => "after"}),
        call("c", "read_file", %{"path" => "seq.txt"})
      ])

      {:ok, _reply, messages} = converse(agent, cwd)
      assert [{"a", first}, {"b", _}, {"c", last}] = tool_results(messages)

      # Running every read together first would have made both of these say "before", and
      # nothing would have complained.
      assert first =~ "before"
      assert last =~ "after"
    end
  end

  describe "safety" do
    test "two writes to one file compose instead of racing", %{agent: agent, cwd: cwd} do
      asks([
        call("a", "write_file", %{"path" => "w.txt", "content" => "one"}),
        call("b", "write_file", %{"path" => "w.txt", "content" => "two"})
      ])

      {:ok, _reply, _messages} = converse(agent, cwd)

      # Run at once, both would land and the loser's write would vanish with no error. The
      # last write the model asked for is the one that must survive.
      assert File.read!(Path.join(workspace(agent.name), "w.txt")) == "two"
    end

    test "a denied tool never runs, and the ones beside it still do", %{cwd: cwd} do
      agent = %Agent{
        name: "gated",
        model: "mock",
        system_prompt: "hi",
        tools: ["read_file", "write_file"],
        max_iterations: 3
      }

      Config.put_agent(agent)
      ws = workspace(agent.name)
      File.write!(Path.join(ws, "r.txt"), "readable")

      asks([
        call("a", "read_file", %{"path" => "r.txt"}),
        call("b", "write_file", %{"path" => "denied.txt", "content" => "nope"})
      ])

      {:ok, _reply, messages} = converse(agent, cwd, authorize: fn _n, _a, _c -> :deny end)

      assert [{"a", read}, {"b", denied}] = tool_results(messages)
      assert read =~ "readable"
      assert denied =~ "did not authorize"

      # The gate is a gate, not a warning.
      refute File.exists?(Path.join(ws, "denied.txt"))
    end

    test "the permission gate asks one question at a time", %{cwd: cwd, home: home} do
      # Every built-in concurrent tool happens to be read-only, so none of them is gated
      # today and the gate can't fan out by accident. A plugin is where the two meet: it is
      # risky by default (we know nothing about it) and its author may well declare it
      # concurrent. Three prompts arriving at a Telegram user at once is the failure.
      plugin = """
      defmodule PepeParallelTest.Peek do
        @behaviour Pepe.Tools.Tool
        import Pepe.Tools.Tool, only: [function: 3]

        def name, do: "peek"
        def concurrent?, do: true

        def spec do
          function("peek", "Peek at something.", %{
            "type" => "object",
            "properties" => %{"at" => %{"type" => "string"}},
            "required" => ["at"]
          })
        end

        def run(%{"at" => at}, _ctx), do: {:ok, "peeked: " <> at}
      end
      """

      File.mkdir_p!(Path.join(home, "plugins"))
      File.write!(Path.join([home, "plugins", "peek.exs"]), plugin)

      agent = %Agent{
        name: "asker",
        model: "mock",
        system_prompt: "hi",
        tools: ["peek"],
        max_iterations: 3
      }

      Config.put_agent(agent)

      asks([
        call("a", "peek", %{"at" => "one"}),
        call("b", "peek", %{"at" => "two"}),
        call("c", "peek", %{"at" => "three"})
      ])

      # Records how many prompts are open at once.
      {:ok, _} = Elixir.Agent.start_link(fn -> {0, 0} end, name: :pt_open)

      authorize = fn _name, _args, _ctx ->
        Elixir.Agent.update(:pt_open, fn {open, peak} -> {open + 1, max(peak, open + 1)} end)
        Process.sleep(20)
        Elixir.Agent.update(:pt_open, fn {open, peak} -> {open - 1, peak} end)
        :once
      end

      {:ok, _reply, messages} = converse(agent, cwd, authorize: authorize)

      # The tool did run, and concurrently - the gate being serial must not have made it serial.
      assert [{"a", _}, {"b", _}, {"c", _}] = tool_results(messages)

      {_open, peak} = Elixir.Agent.get(:pt_open, & &1)
      assert peak == 1, "the gate must be asked serially, saw #{peak} prompts open at once"
    end
  end

  describe "a concurrent tool that dies" do
    test "does not take the turn down or orphan the calls beside it", %{cwd: cwd, home: home} do
      # A plugin is risky and may declare itself concurrent, and it may `exit`/`throw` past the
      # tools' own rescue (which only catches `raise`). In a batch, that goes through
      # `Task.async_stream`, which reports it as `{:exit, _}` rather than `{:ok, _}`. If the
      # runtime only matched `{:ok, _}`, the whole turn would crash and every tool_call id in
      # the batch would be left unanswered, making the model's next request malformed. Instead
      # the dead call becomes an error result under its own id, and its neighbour still answers.
      boom = """
      defmodule PepeParallelTest.Boom do
        @behaviour Pepe.Tools.Tool
        import Pepe.Tools.Tool, only: [function: 3]

        def name, do: "boom"
        def concurrent?, do: true

        def spec do
          function("boom", "Explodes.", %{"type" => "object", "properties" => %{}})
        end

        def run(_args, _ctx), do: exit(:kaboom)
      end
      """

      fine = """
      defmodule PepeParallelTest.Fine do
        @behaviour Pepe.Tools.Tool
        import Pepe.Tools.Tool, only: [function: 3]

        def name, do: "fine"
        def concurrent?, do: true

        def spec do
          function("fine", "Works.", %{"type" => "object", "properties" => %{}})
        end

        def run(_args, _ctx), do: {:ok, "i am fine"}
      end
      """

      File.mkdir_p!(Path.join(home, "plugins"))
      File.write!(Path.join([home, "plugins", "boom.exs"]), boom)
      File.write!(Path.join([home, "plugins", "fine.exs"]), fine)

      agent = %Agent{
        name: "riskt",
        model: "mock",
        system_prompt: "hi",
        tools: ["boom", "fine"],
        auto_approve: ["*"],
        max_iterations: 3
      }

      Config.put_agent(agent)

      asks([
        call("a", "boom", %{}),
        call("b", "fine", %{})
      ])

      {:ok, _reply, messages} = converse(agent, cwd)

      # Both ids came back: the turn survived, and neither call was orphaned.
      assert [{"a", died}, {"b", ok}] = tool_results(messages)
      assert died =~ "boom" and died =~ "crashed"
      assert ok =~ "i am fine"
    end
  end

  describe "speed" do
    test "tools that wait on a network wait at the same time", %{cwd: cwd} do
      # A server that takes 300ms to answer anything. Serially, three calls are 900ms;
      # together they are one wait. The assertion is deliberately loose (under 700ms rather
      # than under 400ms) so it fails on a regression to serial, not on a slow machine.
      {:ok, slow} =
        Bandit.start_link(
          plug: fn conn, _ ->
            Process.sleep(300)
            Plug.Conn.send_resp(conn, 200, "ok")
          end,
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(slow)
      url = "http://127.0.0.1:#{port}/"

      agent = %Agent{
        name: "fetcher",
        model: "mock",
        system_prompt: "hi",
        tools: ["fetch_url"],
        auto_approve: ["*"],
        max_iterations: 3
      }

      Config.put_agent(agent)

      asks([
        call("a", "fetch_url", %{"url" => url}),
        call("b", "fetch_url", %{"url" => url}),
        call("c", "fetch_url", %{"url" => url})
      ])

      {micros, {:ok, _reply, messages}} = :timer.tc(fn -> converse(agent, cwd) end)
      ms = div(micros, 1000)

      assert [_, _, _] = tool_results(messages)
      assert ms < 700, "three 300ms fetches took #{ms}ms, which is the serial cost"
    end
  end
end
