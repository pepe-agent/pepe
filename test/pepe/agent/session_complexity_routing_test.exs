defmodule Pepe.Agent.SessionComplexityRoutingTest do
  @moduledoc """
  A `triage_model` judges a session's first turn before it runs (a raw
  classification call, no agent involved); a SIMPLE verdict downgrades (and
  keeps) the session on `simple_model`. The agent's own model is the default
  otherwise - COMPLEX and any triage failure (bad model name, unreachable,
  timeout) must never block or change the outcome of the real turn.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Replies a fixed string and records which "role" (main/triage/simple) got
  # hit, so a test can assert both on the reply's origin and on call counts.
  defmodule RolePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      send(:pepe_cr_test, {:hit, Keyword.fetch!(opts, :role)})

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => Keyword.fetch!(opts, :reply)}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    Process.register(self(), :pepe_cr_test)

    home = Path.join(System.tmp_dir!(), "pepe_cr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    main_port = start_mock(:main, "ok")
    simple_port = start_mock(:simple, "ok from simple")

    Config.put_model(%Model{name: "main-mock", base_url: "http://localhost:#{main_port}", api_key: "x", model: "m"})
    Config.put_model(%Model{name: "simple-mock", base_url: "http://localhost:#{simple_port}", api_key: "x", model: "m"})

    %{}
  end

  defp start_mock(role, reply) do
    {:ok, server} = Bandit.start_link(plug: {RolePlug, role: role, reply: reply}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defp put_main_agent(triage_model, simple_model \\ "simple-mock") do
    Config.put_agent(%Agent{
      name: "main",
      model: "main-mock",
      tools: [],
      max_iterations: 5,
      triage_model: triage_model,
      simple_model: simple_model
    })
  end

  defp put_triage_model(reply) do
    port = start_mock(:triage, reply)
    Config.put_model(%Model{name: "triage-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    "triage-mock"
  end

  defp new_key, do: "test:complexity:#{System.unique_integer([:positive])}"

  test "a SIMPLE verdict downgrades this turn AND stays downgraded on the next, without triaging again" do
    triage = put_triage_model("SIMPLE")
    put_main_agent(triage)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :triage}, 2_000
    assert_receive {:hit, :simple}, 2_000
    refute_receive {:hit, :main}, 200

    assert {:ok, _reply} = Session.chat(key, "again")
    assert_receive {:hit, :simple}, 2_000
    refute_receive {:hit, :triage}, 200
    refute_receive {:hit, :main}, 200
  end

  test "a non-SIMPLE verdict leaves the session on its own model" do
    triage = put_triage_model("COMPLEX, this needs real thought")
    put_main_agent(triage)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :triage}, 2_000
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :simple}, 200

    assert {:ok, _reply} = Session.chat(key, "again")
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :triage}, 200
  end

  test "an unresolvable triage_model name fails open onto the agent's own model" do
    put_main_agent("no-such-model")
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :simple}, 200
  end

  test "an unreachable triage model fails open onto the agent's own model" do
    Config.put_model(%Model{name: "dead-triage", base_url: "http://localhost:1", api_key: "x", model: "m"})
    put_main_agent("dead-triage")
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :main}, 8_000
    refute_receive {:hit, :simple}, 200
  end

  test "no simple_model configured skips triage entirely, even with a triage_model set" do
    triage = put_triage_model("SIMPLE")
    put_main_agent(triage, nil)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :triage}, 200
  end

  test "a crash inside the triage call fails open onto the agent's own model, not the whole turn" do
    # A malformed base_url makes the underlying HTTP call exit abnormally instead of
    # returning {:error, _} (Req itself raises/exits on a URL like this) - regression
    # coverage for triage_verdict/2's Task.async closure: Task.async links the spawned
    # task to its caller, so without an inner rescue/catch this abnormal exit would
    # propagate via the link and take the whole turn down instead of failing open.
    Config.put_model(%Model{name: "crashy-triage", base_url: "http://\0bad", api_key: "x", model: "m"})
    put_main_agent("crashy-triage")
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :simple}, 200
  end

  test "an already-set model override skips triage entirely" do
    triage = put_triage_model("SIMPLE")
    put_main_agent(triage)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    assert Session.set_model(key, "main-mock") == :ok

    assert {:ok, _reply} = Session.chat(key, "hello")
    assert_receive {:hit, :main}, 2_000
    refute_receive {:hit, :triage}, 200
    refute_receive {:hit, :simple}, 200
  end
end
