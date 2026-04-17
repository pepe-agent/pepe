defmodule Pepe.AgentLoopMaxIterationsTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A model that never finishes on its own - it always proposes a `bash` tool call
  # as long as the request offers tools, and only replies with real content once
  # the request has none (exactly what the runtime's final no-tools nudge sends).
  defmodule NeverFinishesPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      message =
        if req["tools"] in [nil, []] do
          %{"role" => "assistant", "content" => "Summary: found 3 things, ran out of turns."}
        else
          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => ~s({"command":"echo hi"})}
          }

          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        end

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(message["tool_calls"], do: "tool_calls", else: "stop")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_maxiter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: NeverFinishesPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = %Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    }

    Config.put_model(model)
    Config.put_agent(%Agent{name: "grinder", model: "mock", tools: ["bash"], max_iterations: 3})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: Config.get_agent("grinder")}
  end

  test "running out of turns still returns the model's best summary, not a bare stop marker", %{agent: agent} do
    assert {:ok, content, _msgs} = Runtime.converse(agent, "do something that never finishes")
    assert content == "Summary: found 3 things, ran out of turns."
  end

  test "the final nudge call carries no tools, so the model can't ask for more turns", %{agent: agent} do
    events = self()

    {:ok, _content, _msgs} =
      Runtime.converse(agent, "do something that never finishes", on_event: fn ev -> send(events, {:ev, ev}) end)

    # 3 iterations of the ordinary loop each produce a tool_call/tool_result pair;
    # the final nudge produces no further tool_call - it's a plain assistant reply.
    assert_received {:ev, {:tool_call, "bash", _}}
    assert_received {:ev, {:done, "Summary: found 3 things, ran out of turns."}}
  end
end
