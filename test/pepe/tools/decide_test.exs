defmodule Pepe.Tools.DecideTest do
  @moduledoc """
  The `decide` tool: an agent asks the decision model for one pick among options it names, and
  gets the choice with a confidence band to branch on. It exists only while a decision
  connection is reachable for the agent, falls back to a normal model when that connection
  cannot answer, and never turns a failed call into an invented answer.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Tools
  alias Pepe.Tools.Decide

  @options [
    %{"name" => "urgent", "description" => "Needs an answer today."},
    %{"name" => "normal", "description" => "Can wait."},
    %{"name" => "other", "description" => "None of the above."}
  ]

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_decidetool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Pepe.LLM.Cooldown.clear(%Model{name: "jev"})
    on_exit(fn -> Pepe.LLM.Cooldown.clear(%Model{name: "jev"}) end)
    Process.register(self(), :pepe_decidetool_test)
    :ok
  end

  defp serve(plug) do
    {:ok, server} = Bandit.start_link(plug: plug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp json(conn, status, payload) do
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp put_jev(choice, confidence, status \\ 200, fallbacks \\ []) do
    port =
      serve(fn conn, _ ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(:pepe_decidetool_test, {:jev, Jason.decode!(body)})

        if status == 200,
          do:
            json(conn, 200, %{
              "answers" => %{"decision" => %{"choice" => choice, "confidence" => confidence}},
              "usage" => %{"input_tokens" => 50, "output_tokens" => 4}
            }),
          else: json(conn, status, %{"error" => "no credit"})
      end)

    Config.put_model(%Model{
      name: "jev",
      base_url: "http://127.0.0.1:#{port}",
      api_key: "k",
      model: "jev-latest",
      api: "typesafe-systemone",
      fallbacks: fallbacks
    })
  end

  defp put_chat(reply) do
    port =
      serve(fn conn, _ ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(:pepe_decidetool_test, {:chat, Jason.decode!(body)})

        json(conn, 200, %{
          "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => reply}, "finish_reason" => "stop"}]
        })
      end)

    Config.put_model(%Model{name: "cheap", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})
  end

  defp agent, do: %Agent{name: "sales", model: "cheap", tools: ["decide"]}
  defp ctx, do: %{agent: agent()}

  defp args(extra \\ %{}), do: Map.merge(%{"question" => "How urgent is this?", "text" => "My site is down!", "options" => @options}, extra)

  test "it is offered only when a decision connection is reachable for the agent" do
    names = fn -> for s <- Tools.specs(["decide"], ctx()) || [], do: s["function"]["name"] end

    assert names.() == []
    put_jev("urgent", 0.95)
    assert names.() == ["decide"]

    call = %{"function" => %{"name" => "decide", "arguments" => Jason.encode!(args())}}
    assert Tools.execute(call, ctx()) =~ "decision: urgent"
  end

  test "the call is not offered, or run, on a turn with no decision connection" do
    call = %{"function" => %{"name" => "decide", "arguments" => Jason.encode!(args())}}
    assert Tools.execute(call, ctx()) =~ "not available on this turn"
  end

  test "it sends the question, the text and the options, and reports the choice with a confidence band" do
    put_jev("urgent", 0.95)

    assert {:ok, report} = Decide.run(args(), ctx())
    assert report =~ "decision: urgent"
    assert report =~ "confidence: 0.95 (high: act on it)"
    assert report =~ "answered by: jev"

    assert_received {:jev, body}
    assert body["state"] == "My site is down!"
    assert body["questions"]["decision"]["instructions"] == "How urgent is this?"
    assert body["questions"]["decision"]["criteria"]["urgent"] == "Needs an answer today."
  end

  test "the confidence band tells the agent what to do: medium confirms, low does not act" do
    put_jev("normal", 0.7)
    assert {:ok, medium} = Decide.run(args(), ctx())
    assert medium =~ "medium: confirm with the user or check before acting"

    put_jev("normal", 0.2)
    assert {:ok, low} = Decide.run(args(), ctx())
    assert low =~ "low: do not act on it, ask the user or decide yourself"
  end

  test "with no credit a normal model backs it up, and says there is no confidence to rely on" do
    put_chat("urgent")
    put_jev("urgent", 0.9, 402, ["cheap"])

    assert {:ok, report} = Decide.run(args(), ctx())
    assert report =~ "decision: urgent"
    assert report =~ "confidence: not available"
    assert report =~ "cheap"

    assert_received {:chat, request}
    system = request["messages"] |> hd() |> Map.fetch!("content")
    assert system =~ "How urgent is this?"
    assert system =~ "- urgent: Needs an answer today."
  end

  test "when nobody can answer it says so instead of inventing a choice" do
    put_jev("urgent", 0.9, 500)

    assert {:error, message} = Decide.run(args(), ctx())
    assert message =~ "decide this yourself or ask the user"
  end

  test "bad arguments are refused with a reason the agent can fix" do
    put_jev("urgent", 0.9)

    assert {:error, message} = Decide.run(args(%{"options" => [hd(@options)]}), ctx())
    assert message =~ "between 2 and"

    dup = [hd(@options), hd(@options)]
    assert {:error, message} = Decide.run(args(%{"options" => dup}), ctx())
    assert message =~ "different from each other"

    blank = [hd(@options), %{"name" => "x", "description" => " "}]
    assert {:error, message} = Decide.run(args(%{"options" => blank}), ctx())
    assert message =~ "non-empty"

    assert {:error, message} = Decide.run(%{"question" => "q"}, ctx())
    assert message =~ "needs `question`"
  end

  test "an agent in another project does not reach this project's decision connection" do
    Config.add_project("acme", %{})
    put_jev("urgent", 0.95)
    # `jev` belongs to the default project; an acme agent has none of its own.
    outsider = %Agent{name: "acme/sales", model: "cheap", tools: ["decide"]}

    assert Pepe.Decide.connections_for(outsider) == []
    assert Pepe.Decide.connections_for(agent()) |> Enum.map(& &1.name) == ["jev"]
  end
end
