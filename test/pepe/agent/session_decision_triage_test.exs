defmodule Pepe.Agent.SessionDecisionTriageTest do
  @moduledoc """
  A decision connection as an agent's `triage_model`, through a real session: the cheap way
  to sort the first message of a conversation. What matters is what happens when it cannot
  answer (no credit) or is not sure: the connection's own backup, an ordinary chat model,
  decides exactly as the triage model always did, and the conversation is never blocked.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  defmodule ChatPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      send(:pepe_dt_test, {:hit, Keyword.fetch!(opts, :role)})

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => Keyword.fetch!(opts, :reply)}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  defmodule JevPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      send(:pepe_dt_test, {:hit, :jev})

      {status, payload} =
        case opts[:status] do
          nil ->
            {200,
             %{
               "answers" => %{"decision" => %{"type" => "choice", "choice" => opts[:choice], "confidence" => opts[:confidence]}},
               "usage" => %{"input_tokens" => 100, "output_tokens" => 5}
             }}

          status ->
            {status, %{"error" => "payment required"}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
    end
  end

  setup do
    Process.register(self(), :pepe_dt_test)
    home = Path.join(System.tmp_dir!(), "pepe_dt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)
    Pepe.LLM.Cooldown.clear(%Model{name: "jev"})
    on_exit(fn -> Pepe.LLM.Cooldown.clear(%Model{name: "jev"}) end)

    chat = fn name, role, reply ->
      port = start(ChatPlug, role: role, reply: reply)
      Config.put_model(%Model{name: name, base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    end

    chat.("main-mock", :main, "ok")
    chat.("simple-mock", :simple, "ok from simple")
    chat.("triage-mock", :triage, "SIMPLE")
    :ok
  end

  defp start(plug, opts) do
    {:ok, server} = Bandit.start_link(plug: {plug, opts}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defp put_jev(opts) do
    port = start(JevPlug, opts)

    Config.put_model(%Model{
      name: "jev",
      base_url: "http://localhost:#{port}",
      api_key: "k",
      model: "jev-latest",
      api: "typesafe-systemone",
      fallbacks: ["triage-mock"]
    })

    Config.put_agent(%Agent{
      name: "main",
      model: "main-mock",
      tools: [],
      max_iterations: 5,
      triage_model: "jev",
      simple_model: "simple-mock"
    })
  end

  defp session do
    key = "test:decision:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")
    key
  end

  test "a confident simple answer from the decision connection downgrades the turn, no chat model asked" do
    put_jev(choice: "simple", confidence: 0.95)

    assert {:ok, _reply} = Session.chat(session(), "hello")
    assert_receive {:hit, :jev}, 2_000
    assert_receive {:hit, :simple}, 2_000
    refute_receive {:hit, :triage}, 200
    refute_receive {:hit, :main}, 200
  end

  test "with no credit the backup chat model decides, and the next conversation skips the failed call" do
    put_jev(status: 402)

    assert {:ok, _reply} = Session.chat(session(), "hello")
    assert_receive {:hit, :jev}, 2_000
    assert_receive {:hit, :triage}, 2_000
    assert_receive {:hit, :simple}, 2_000

    assert {:ok, _reply} = Session.chat(session(), "and another one")
    assert_receive {:hit, :triage}, 2_000
    assert_receive {:hit, :simple}, 2_000
    refute_receive {:hit, :jev}, 200
  end

  test "an unsure answer for the cheap model is double checked by the backup chat model" do
    put_jev(choice: "simple", confidence: 0.3)

    assert {:ok, _reply} = Session.chat(session(), "hello")
    assert_receive {:hit, :jev}, 2_000
    assert_receive {:hit, :triage}, 2_000
    assert_receive {:hit, :simple}, 2_000
  end

  test "a decision connection that says complex keeps the turn on the agent's own model" do
    put_jev(choice: "complex", confidence: 0.9)

    assert {:ok, _reply} = Session.chat(session(), "hello")
    assert_receive {:hit, :jev}, 2_000
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :simple}, 200
  end
end
