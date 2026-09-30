defmodule Pepe.Tools.RoutePreflightTest do
  @moduledoc """
  A `switch_agent`/`send_to_agent` call that its own route allowlist would refuse must be
  answered on the spot, never parked for a human's approval: an approval nobody can usefully
  give (the call is refused the moment it runs) is a dead end for the user and the model.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Tools

  # First request: the model tries to switch to a peer. After the tool answers, it repeats
  # the tool's answer verbatim, so the test reads what happened from the reply.
  defmodule Switcher do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      message =
        case Enum.find(req["messages"], &(&1["role"] == "tool")) do
          nil ->
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "switch_agent", "arguments" => ~s({"target":"CarenAI"})}
                }
              ]
            }

          tool ->
            %{"role" => "assistant", "content" => tool["content"]}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # Reports the names of the tools the request declared.
  defmodule ToolNames do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      names = (Jason.decode!(body)["tools"] || []) |> Enum.map(& &1["function"]["name"]) |> Enum.sort()
      message = %{"role" => "assistant", "content" => Jason.encode!(names)}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_preflight_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp serve(plug, home) do
    {:ok, server} = Bandit.start_link(plug: plug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Config.put_model(%Model{name: "m", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})
    home
  end

  defp router(can_message) do
    %Agent{
      name: "default/CarenOps",
      model: "m",
      system_prompt: "router",
      tools: ["switch_agent", "send_to_agent"],
      can_message: can_message,
      max_iterations: 3
    }
  end

  describe "Tools.preflight/3" do
    test "refuses a switch to an agent that is not on can_message" do
      ctx = %{agent: router([]), session_key: "slack:1"}

      assert {:refuse, out} = Tools.preflight("switch_agent", ~s({"target":"CarenAI"}), ctx)
      assert out =~ "isn't available"
      assert out =~ "Error:"
    end

    test "allows a switch to a routed, existing agent" do
      Config.put_agent(%Agent{name: "default/CarenAI", system_prompt: "x", tools: []})
      ctx = %{agent: router(["default/CarenAI"]), session_key: "slack:1"}

      assert Tools.preflight("switch_agent", ~s({"target":"CarenAI"}), ctx) == :ok
    end

    test "refuses a message to an agent that is not on can_message, allows a routed one" do
      Config.put_agent(%Agent{name: "default/CarenAI", system_prompt: "x", tools: []})

      assert {:refuse, out} =
               Tools.preflight("send_to_agent", ~s({"to":"CarenAI","message":"hi"}), %{agent: router([])})

      assert out =~ "isn't available"

      assert Tools.preflight(
               "send_to_agent",
               ~s({"to":"CarenAI","message":"hi"}),
               %{agent: router(["default/CarenAI"])}
             ) == :ok
    end

    test "a tool with no preflight, and arguments that don't decode, are left to the normal path" do
      assert Tools.preflight("bash", ~s({"command":"true"}), %{}) == :ok
      assert Tools.preflight("switch_agent", "not json", %{agent: router([])}) == :ok
    end
  end

  test "an unroutable switch is answered directly, not parked for a human's approval", %{home: home} do
    serve(Switcher, home)

    {:ok, reply, _} =
      Runtime.converse(router([]), "quais clientes voce conhece?", cwd: home, session_key: "slack:1")

    assert reply =~ "isn't available"
    refute reply =~ "parked"
    refute reply =~ "human"
  end

  test "an agent with no can_message is not offered the routing tools; one with routes is", %{home: home} do
    serve(ToolNames, home)

    {:ok, without, _} = Runtime.converse(router([]), "hi", cwd: home)
    refute "switch_agent" in Jason.decode!(without)
    refute "send_to_agent" in Jason.decode!(without)

    {:ok, with_routes, _} = Runtime.converse(router(["default/CarenAI"]), "hi", cwd: home)
    assert Jason.decode!(with_routes) == ["send_to_agent", "switch_agent"]
  end
end
