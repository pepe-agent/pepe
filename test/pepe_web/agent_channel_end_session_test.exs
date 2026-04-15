defmodule PepeWeb.AgentChannelEndSessionTest do
  @moduledoc """
  When the agent calls `end_session`, the channel pushes an explicit "session_ended"
  event (in addition to the normal "tool_result") - a client shouldn't need to know
  anything about tool internals to notice the conversation ended.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  # A mock model that always calls end_session on the first turn - streaming-aware
  # (AgentChannel always runs with stream: true), mirroring Pepe.Test.MockLLM's
  # SSE-vs-plain-JSON branching.
  defmodule EndSessionPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      req = Jason.decode!(body)
      stream? = req["stream"] == true
      last = List.last(req["messages"])

      if last["role"] == "tool" do
        respond(conn, stream?, %{content: "Bye!", tool_calls: nil})
      else
        tool_call = %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "end_session", "arguments" => "{}"}
        }

        respond(conn, stream?, %{content: nil, tool_calls: [tool_call]})
      end
    end

    defp respond(conn, false, %{content: content, tool_calls: tool_calls}) do
      message =
        %{"role" => "assistant", "content" => content}
        |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(tool_calls, do: "tool_calls", else: "stop")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp respond(conn, true, %{content: content, tool_calls: tool_calls}) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      chunks =
        if tool_calls do
          [delta_chunk(%{"tool_calls" => tool_calls}), finish_chunk("tool_calls")]
        else
          [delta_chunk(%{"content" => content}), finish_chunk("stop")]
        end

      Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end

    defp delta_chunk(delta) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]})}\n\n"
    end

    defp finish_chunk(reason) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: EndSessionPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_aces_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Config.Agent{name: "assistant", model: "mock", tools: ["end_session"], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "session_ended is pushed alongside the end_session tool_result" do
    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:assistant", %{"session" => "es1"})

    push(socket, "prompt", %{"text" => "bye"})

    assert_push "tool_result", %{name: "end_session"}, 2_000
    assert_push "session_ended", %{}, 2_000
    assert_push "done", %{content: "Bye!"}, 2_000
  end

  test "an ordinary reply never gets a session_ended push" do
    {:ok, plain_server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, plain_port}} = ThousandIsland.listener_info(plain_server)
    Config.put_model(%Config.Model{name: "plain-mock", base_url: "http://localhost:#{plain_port}", api_key: "x", model: "m"})
    Config.put_agent(%Config.Agent{name: "plain", model: "plain-mock", tools: [], max_iterations: 5})

    {:ok, socket} = connect(PepeWeb.AgentSocket, %{}, connect_info: %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, _reply, socket} = subscribe_and_join(socket, "agent:plain", %{"session" => "es2"})

    push(socket, "prompt", %{"text" => "hi"})

    assert_push "done", %{}, 2_000
    refute_push "session_ended", %{}, 200

    Process.exit(plain_server, :normal)
  end
end
