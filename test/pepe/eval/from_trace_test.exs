defmodule Pepe.Eval.FromTraceTest do
  @moduledoc """
  A conversation that already happened, promoted into a case that has to keep happening.

  The test that matters is the last one: it does the thing this feature exists to prevent.
  An agent looks something up, gets it right, and the run is kept. Somebody then edits the
  agent so it stops looking things up and answers from memory instead. Nothing crashes and
  no existing test fails - the reply is even plausible. The promoted case is what notices.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Eval
  alias Pepe.Eval.FromTrace
  alias Pepe.Trace

  # A model that reaches for `read_file` while the agent's tools allow it, and answers from
  # memory when they do not. Exactly the shape of the regression a persona edit causes.
  defmodule Plug1 do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      answered? = Enum.any?(req["messages"], &(&1["role"] == "tool"))
      tools = req["tools"] || []

      message =
        cond do
          answered? ->
            %{"role" => "assistant", "content" => "The price is 42 euros."}

          Enum.any?(tools, &(&1["function"]["name"] == "read_file")) ->
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => ~s({"path":"price.txt"})}
                }
              ]
            }

          true ->
            # No tool to reach for, so it invents an answer. It even sounds right.
            %{"role" => "assistant", "content" => "The price is 42 euros."}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_ft_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Plug1, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "m", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    agent = %Agent{
      name: "clerk",
      model: "m",
      system_prompt: "hi",
      tools: ["read_file"],
      auto_approve: ["*"],
      max_iterations: 3
    }

    Config.put_agent(agent)

    ws = Pepe.Agent.Workspace.dir("clerk")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "price.txt"), "42 euros")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent, home: home}
  end

  # Run a turn for real, so a real trace lands on disk, and hand back its id.
  defp recorded_run(agent, prompt) do
    {:ok, _reply, _msgs} = Runtime.converse(agent, prompt, cwd: File.cwd!(), session_key: "s1")
    [trace | _] = Trace.recent("default", 5)
    trace["id"]
  end

  test "the tools the agent used become the assertion", %{agent: agent} do
    id = recorded_run(agent, "what is the price?")

    assert {:ok, kase} = FromTrace.build("default", id)

    assert kase["agent"] == "clerk"
    assert kase["prompt"] == "what is the price?"
    assert kase["from_trace"] == id
    assert kase["expect"]["tool_called"] == ["read_file"]

    # The reply is kept as documentation, not as an assertion: two runs never produce the
    # same sentence, and a case that demands one gets muted and then protects nothing.
    assert kase["recorded"] =~ "42"
    refute Map.has_key?(kase["expect"], "matches")
  end

  test "words a human says were the point do get asserted", %{agent: agent} do
    id = recorded_run(agent, "what is the price?")

    assert {:ok, kase} = FromTrace.build("default", id, contains: ["42 euros"])
    assert kase["expect"]["contains"] == ["42 euros"]
  end

  test "promoting writes a runnable case into a suite", %{agent: agent} do
    id = recorded_run(agent, "what is the price?")

    assert {:ok, _} = FromTrace.promote("default", id, "recorded")

    assert [kase] = Eval.load("recorded")
    assert kase["from_trace"] == id

    # And it runs, green, against the agent as it stands today.
    assert %{passed: true, tools: ["read_file"]} = Eval.run_case(kase, cwd: File.cwd!())
  end

  test "the same conversation is not promoted twice", %{agent: agent} do
    id = recorded_run(agent, "what is the price?")

    assert {:ok, _} = FromTrace.promote("default", id, "recorded")
    # Structured error the UI/CLI can translate, and a helper the dashboard uses to hide the button.
    assert {:error, :already_recorded} = FromTrace.promote("default", id, "recorded")
    assert FromTrace.already_case?("recorded", id)

    assert [_only_one] = Eval.load("recorded")
  end

  test "a run that failed is not something to keep doing" do
    # A trace of a turn that died. Promoting it would freeze the failure as the expectation
    # and, worse, hand you a green suite for it.
    Pepe.Repo.insert_all(Pepe.Trace.Entry, [
      %{
        id: "dead",
        scope: "default",
        at: System.os_time(:second),
        agent: "clerk",
        prompt: "what is the price?",
        outcome: %{"kind" => "error", "reason" => ":no_model_configured"},
        events: []
      }
    ])

    assert {:error, why} = FromTrace.build("default", "dead")
    assert why =~ "failed"
  end

  test "it catches the regression it exists for: the agent stops looking things up", %{agent: agent} do
    id = recorded_run(agent, "what is the price?")
    assert {:ok, _} = FromTrace.promote("default", id, "recorded", contains: ["42"])
    [kase] = Eval.load("recorded")

    # Green today.
    assert %{passed: true} = Eval.run_case(kase, cwd: File.cwd!())

    # Now somebody "tidies up" the agent and takes read_file away. It still answers, and the
    # answer still says 42 euros, so every assertion about the *reply* passes. Nothing
    # crashes. Nothing else in the suite notices. This is what a silent regression looks
    # like: the agent has stopped consulting the file and started reciting from memory, and
    # tomorrow the price changes.
    Config.put_agent(%{agent | tools: []})

    assert %{passed: false, failures: failures, reply: reply} = Eval.run_case(kase, cwd: File.cwd!())
    assert reply =~ "42"
    assert Enum.any?(failures, &(&1 =~ "read_file"))
  end
end
