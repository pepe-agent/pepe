defmodule Pepe.Agent.SessionModelOverrideTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A minimal chat-completions mock that always answers with a fixed marker, so a
  # test can tell which of two model connections actually served a run.
  defmodule MarkerPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, marker: marker) do
      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => marker}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_modeloverride_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server_a} = Bandit.start_link(plug: {MarkerPlug, marker: "FROM-A"}, port: 0, scheme: :http)
    {:ok, {_addr, port_a}} = ThousandIsland.listener_info(server_a)

    {:ok, server_b} = Bandit.start_link(plug: {MarkerPlug, marker: "FROM-B"}, port: 0, scheme: :http)
    {:ok, {_addr, port_b}} = ThousandIsland.listener_info(server_b)

    Config.put_model(%Model{name: "model-a", base_url: "http://localhost:#{port_a}", model: "model-a-id"})
    Config.put_model(%Model{name: "model-b", base_url: "http://localhost:#{port_b}", model: "model-b-id"})
    Config.put_agent(%Agent{name: "overrider", model: "model-a", max_iterations: 5})

    on_exit(fn ->
      Process.exit(server_a, :normal)
      Process.exit(server_b, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:override:#{System.unique_integer([:positive])}"}
  end

  test "set_model overrides the session's effective model without touching the agent", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "overrider")

    assert Session.status(key).model == "model-a-id"
    assert {:ok, "FROM-A"} = Session.chat(key, "hi")

    assert Session.set_model(key, "model-b") == :ok
    assert Session.status(key).model == "model-b-id"
    assert {:ok, "FROM-B"} = Session.chat(key, "hi again")

    # The agent's own persisted model is never touched by a session-only change.
    assert Config.get_agent("overrider").model == "model-a"
  end

  test "clearing the override (nil) falls back to the agent's own model", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "overrider")

    Session.set_model(key, "model-b")
    assert Session.status(key).model == "model-b-id"

    Session.set_model(key, nil)
    assert Session.status(key).model == "model-a-id"
    assert {:ok, "FROM-A"} = Session.chat(key, "hi")
  end
end
