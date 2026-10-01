defmodule Pepe.DecideTest do
  @moduledoc """
  `Pepe.Decide` against a real local server standing in for the decision model
  (`Pepe.Decide.Jev`) and another for an ordinary chat model: what it asks, what it trusts,
  and what happens when the decision connection has no credit.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Decide
  alias Pepe.LLM

  @question %{
    state: "what is the capital of France?",
    instructions: "Is this a quick everyday question?",
    criteria: %{"simple" => "A quick question.", "complex" => "Needs deep reasoning."},
    default: "complex",
    min_confidence: 0.7,
    chat_system: "Reply SIMPLE or COMPLEX.",
    chat_user: "what is the capital of France?"
  }

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_decide_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)
    # The pause a failed decision connection earns lives in memory, shared by every test in the
    # VM, and these tests reuse the connection's name.
    Pepe.LLM.Cooldown.clear(%Model{name: "jev"})
    on_exit(fn -> Pepe.LLM.Cooldown.clear(%Model{name: "jev"}) end)
    Process.register(self(), :pepe_decide_test)
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

  # A stand-in for the decision API: answers with `choice`/`confidence`, or `status` alone.
  defp decision_server(choice, confidence, status \\ 200) do
    serve(fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(:pepe_decide_test, {:decision_request, Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")})

      if status == 200 do
        json(conn, 200, %{
          "answers" => %{"decision" => %{"type" => "choice", "choice" => choice, "confidence" => confidence}},
          "usage" => %{"input_tokens" => 120, "output_tokens" => 8}
        })
      else
        json(conn, status, %{"error" => "no credit"})
      end
    end)
  end

  # A stand-in for an ordinary chat model that always replies `word`.
  defp chat_server(word) do
    serve(fn conn, _ ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(:pepe_decide_test, :chat_request)

      json(conn, 200, %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => word}, "finish_reason" => "stop"}]})
    end)
  end

  defp put_decision(name, port, fallbacks \\ []) do
    Config.put_model(%Model{
      name: name,
      base_url: "http://127.0.0.1:#{port}",
      api_key: "secret-key",
      model: "jev-latest",
      api: "typesafe-systemone",
      fallbacks: fallbacks
    })
  end

  defp put_chat(name, port), do: Config.put_model(%Model{name: name, base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})

  test "a confident answer from the decision connection is used, with the key and the question sent" do
    put_decision("jev", decision_server("simple", 0.95))

    assert %{choice: "simple", via: "jev"} = Decide.choose(Decide.chain(["jev"]), @question, "default/a")

    assert_received {:decision_request, body, ["Bearer secret-key"]}
    assert body["state"] == "what is the capital of France?"
    assert body["model"] == "jev-latest"
    assert body["questions"]["decision"]["type"] == "choice"
    assert body["questions"]["decision"]["criteria"] == @question.criteria
  end

  test "a decision is metered like any model call: tokens, cost at the connection's price, the project's markup" do
    Config.add_project("acme", %{"markup" => 2.0})
    port = decision_server("simple", 0.95)

    Config.put_model(%Model{
      name: "acme/jev",
      base_url: "http://127.0.0.1:#{port}",
      api_key: "k",
      model: "jev-latest",
      api: "typesafe-systemone",
      input_price: 1_000_000.0,
      output_price: 0.0
    })

    assert %{choice: "simple"} = Decide.choose(Decide.chain(["acme/jev"]), @question, "acme/sales")

    totals = Pepe.Usage.summary("acme", :day).totals
    assert totals.in == 120
    assert totals.out == 8
    # 120 input tokens at 1,000,000 per 1M tokens is 120, and the project's markup doubles it.
    assert_in_delta totals.cost, 120.0, 0.001
    assert_in_delta totals.billable, 240.0, 0.001
  end

  test "the price book knows the decision model out of the box, input tokens only" do
    {input, output} = Pepe.Pricing.seed()["jev"]
    assert input == 0.042
    assert output == 0.0
  end

  test "a hesitant answer for the risky option goes on to the next connection, a normal model" do
    put_chat("cheap", chat_server("SIMPLE"))
    put_decision("jev", decision_server("simple", 0.4), ["cheap"])

    assert %{choice: "simple", via: "cheap"} = Decide.choose(Decide.chain(["jev"]), @question, "default/a")
    assert_received :chat_request
  end

  test "an answer for the safe option is accepted whatever the confidence" do
    put_chat("cheap", chat_server("SIMPLE"))
    put_decision("jev", decision_server("complex", 0.1), ["cheap"])

    assert %{choice: "complex", via: "jev"} = Decide.choose(Decide.chain(["jev"]), @question, "default/a")
    refute_received :chat_request
  end

  test "with no credit the decision connection is skipped for a while and a normal model answers" do
    put_chat("cheap", chat_server("SIMPLE"))
    put_decision("jev", decision_server("simple", 0.99, 402), ["cheap"])
    chain = Decide.chain(["jev"])

    assert %{choice: "simple", via: "cheap"} = Decide.choose(chain, @question, "default/a")
    assert_received {:decision_request, _, _}

    # The second message does not pay for another failed call to the connection with no credit.
    assert %{choice: "simple", via: "cheap"} = Decide.choose(chain, @question, "default/a")
    refute_received {:decision_request, _, _}
  end

  test "when nobody answers the safe default wins, and via says so" do
    put_decision("jev", decision_server("simple", 0.99, 500))

    assert %{choice: "complex", via: nil} = Decide.choose(Decide.chain(["jev"]), @question, "default/a")
  end

  test "an ordinary chat model works as before: the word of the risky option, anything else is the default" do
    put_chat("yes", chat_server("simple"))
    put_chat("no", chat_server("hmm, hard to say"))

    assert %{choice: "simple", via: "yes"} = Decide.choose(Decide.chain(["yes"]), @question, "default/a")
    assert %{choice: "complex", via: "no"} = Decide.choose(Decide.chain(["no"]), @question, "default/a")
  end

  test "the chain follows each connection's own fallbacks and drops names that no longer exist" do
    put_chat("cheap", chat_server("SIMPLE"))
    put_decision("jev", decision_server("simple", 0.9), ["cheap", "gone"])

    assert ["jev", "cheap"] = Enum.map(Decide.chain([nil, "jev", "cheap", "missing"]), & &1.name)
  end

  test "a decision connection refuses to chat, however it got picked" do
    put_decision("jev", decision_server("simple", 0.9))

    assert {:error, message} = LLM.chat(Config.get_model("jev"), [%{"role" => "user", "content" => "hi"}])
    assert message =~ "only makes decisions"
    assert Model.decision?(Config.get_model("jev"))
  end
end
