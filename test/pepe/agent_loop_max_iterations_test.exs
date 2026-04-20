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

  # Like NeverFinishesPlug, but the final no-tools nudge call gets a real HTTP
  # error (e.g. an account hitting its spend budget) instead of a summary.
  defmodule ErrorsOnFinalPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)

      if req["tools"] in [nil, []] do
        send_resp(conn, 402, Jason.encode!(%{"error" => %{"message" => "budget exceeded"}}))
      else
        tool_call = %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "bash", "arguments" => ~s({"command":"echo hi"})}
        }

        message = %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "tool_calls"}]}
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_maxiter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp start_agent(plug) do
    {:ok, server} = Bandit.start_link(plug: plug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    model = %Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"}
    Config.put_model(model)
    Config.put_agent(%Agent{name: "grinder", model: "mock", tools: ["bash"], max_iterations: 3})
    Config.get_agent("grinder")
  end

  test "running out of turns still returns the model's best summary, not a bare stop marker" do
    agent = start_agent(NeverFinishesPlug)
    assert {:ok, content, _msgs} = Runtime.converse(agent, "do something that never finishes")
    assert content == "Summary: found 3 things, ran out of turns."
  end

  test "the final nudge call carries no tools, so the model can't ask for more turns" do
    agent = start_agent(NeverFinishesPlug)
    events = self()

    {:ok, _content, _msgs} =
      Runtime.converse(agent, "do something that never finishes", on_event: fn ev -> send(events, {:ev, ev}) end)

    # 3 iterations of the ordinary loop each produce a tool_call/tool_result pair;
    # the final nudge produces no further tool_call - it's a plain assistant reply.
    assert_received {:ev, {:tool_call, "bash", _}}
    assert_received {:ev, {:done, "Summary: found 3 things, ran out of turns."}}
  end

  test "a real error on the final nudge call surfaces as an error, not a misleading stop marker" do
    agent = start_agent(ErrorsOnFinalPlug)
    assert {:error, _reason} = Runtime.converse(agent, "do something that never finishes")
  end
end
