defmodule Pepe.Agent.SessionMessageLimitTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Usage

  # Always replies with a plain, no-tool-call assistant turn.
  defmodule OkPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sesslimit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: OkPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.add_project("acme", %{"message_limit" => 2})
    Config.put_agent(%Pepe.Config.Agent{name: "acme/bot", model: "mock", tools: [], max_iterations: 5})

    Config.put_agent(%Pepe.Config.Agent{
      name: "acme/unlimited",
      model: "mock",
      tools: [],
      max_iterations: 5,
      exempt_message_limit: true
    })

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "an external-facing session is counted and blocked once the project cap is reached" do
    key = "telegram:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "acme/bot")

    assert {:ok, "ok"} = Session.chat(key, "hi", authorize: nil)
    assert {:ok, "ok"} = Session.chat(key, "hi again", authorize: nil)
    assert Usage.message_count_month_to_date("acme") == 2

    assert {:error, :message_limit_exceeded} = Session.chat(key, "one too many", authorize: nil)
    # The refused message isn't itself counted.
    assert Usage.message_count_month_to_date("acme") == 2
  end

  test "widget and generic webhook-style sessions also count (anything not explicitly internal)" do
    key = "widget:example.com:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "acme/bot")

    Session.chat(key, "hi", authorize: nil)
    assert Usage.message_count_month_to_date("acme") == 1
  end

  test "tui, dashboard (web), and api sessions never count or get blocked" do
    for prefix <- ~w(tui web api) do
      key = "#{prefix}:#{System.unique_integer([:positive])}"
      {:ok, _pid} = SessionSupervisor.ensure(key, "acme/bot")

      assert {:ok, "ok"} = Session.chat(key, "hi", authorize: nil)
    end

    assert Usage.message_count_month_to_date("acme") == 0

    # Project is still under cap (0/2), but even past the cap these must go through -
    # exhaust it via an external session first, then confirm tui still isn't blocked.
    Usage.record_message("acme")
    Usage.record_message("acme")
    assert Usage.over_message_limit?("acme")

    key = "tui:after_cap"
    {:ok, _pid} = SessionSupervisor.ensure(key, "acme/bot")
    assert {:ok, "ok"} = Session.chat(key, "still works", authorize: nil)
  end

  test "an agent exempted from the limit is never blocked or counted, even over cap" do
    Usage.record_message("acme")
    Usage.record_message("acme")
    assert Usage.over_message_limit?("acme")

    key = "telegram:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "acme/unlimited")

    assert {:ok, "ok"} = Session.chat(key, "hi", authorize: nil)
    # Still exactly 2 - the exempt agent's message wasn't counted either.
    assert Usage.message_count_month_to_date("acme") == 2
  end

  test "a project with no message_limit set is never blocked" do
    Config.add_project("free", %{})
    Config.put_agent(%Pepe.Config.Agent{name: "free/bot", model: "mock", tools: [], max_iterations: 5})

    key = "telegram:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "free/bot")

    for _ <- 1..5 do
      assert {:ok, "ok"} = Session.chat(key, "hi", authorize: nil)
    end
  end
end
