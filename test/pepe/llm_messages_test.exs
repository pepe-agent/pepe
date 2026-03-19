defmodule Pepe.LLM.MessagesTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Model
  alias Pepe.LLM.Messages

  defmodule FakeMessages do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(pid), do: pid

    @impl true
    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:req, raw, Enum.into(conn.req_headers, %{})})

      events = [
        ~s({"type":"message_start","message":{"usage":{"input_tokens":7,"output_tokens":1}}}),
        ~s({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        ~s({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}}),
        ~s({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}),
        ~s({"type":"content_block_stop","index":0}),
        ~s({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}),
        ~s({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}),
        ~s({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"SF\\"}"}}),
        ~s({"type":"content_block_stop","index":1}),
        ~s({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}),
        ~s({"type":"message_stop"})
      ]

      body = Enum.map_join(events, "", fn e -> "data: " <> e <> "\n\n" end)

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, body)
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)

    {:ok, server} =
      Bandit.start_link(plug: {FakeMessages, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, port: port}
  end

  defp oauth_model(port) do
    %Model{
      name: "claude",
      base_url: "http://127.0.0.1:#{port}/v1",
      api: "anthropic-messages",
      api_key: "an-access-token",
      model: "claude-sonnet-4-5",
      oauth: %{"provider" => "anthropic"}
    }
  end

  test "assembles assistant text and tool calls from the Messages SSE stream", %{port: port} do
    {parent, ref} = {self(), make_ref()}
    on_delta = fn text -> send(parent, {ref, text}) end

    {:ok, res} =
      Messages.stream_chat(oauth_model(port), [%{"role" => "user", "content" => "weather?"}], on_delta)

    assert_received {^ref, "Hi "}
    assert_received {^ref, "there"}
    assert res.content == "Hi there"

    assert [call] = res.tool_calls
    assert call["id"] == "toolu_1"
    assert call["function"]["name"] == "get_weather"
    assert call["function"]["arguments"] == ~s({"city":"SF"})

    assert res.finish_reason == "tool_calls"
    assert res.usage["prompt_tokens"] == 7
    assert res.usage["completion_tokens"] == 12
  end

  test "translates system, tools and merged tool results into the Anthropic body", %{port: port} do
    messages = [
      %{"role" => "system", "content" => "Be terse."},
      %{"role" => "user", "content" => "hi"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{"id" => "t1", "type" => "function", "function" => %{"name" => "a", "arguments" => "{}"}},
          %{"id" => "t2", "type" => "function", "function" => %{"name" => "b", "arguments" => "{}"}}
        ]
      },
      %{"role" => "tool", "tool_call_id" => "t1", "content" => "ra"},
      %{"role" => "tool", "tool_call_id" => "t2", "content" => "rb"}
    ]

    tools = [%{"type" => "function", "function" => %{"name" => "a", "description" => "d", "parameters" => %{"type" => "object"}}}]

    {:ok, _res} = Messages.chat(oauth_model(port), messages, tools: tools)

    assert_received {:req, raw, headers}
    body = Jason.decode!(raw)

    # OAuth: bearer + the Claude Code client block leads the system array
    assert headers["authorization"] == "Bearer an-access-token"
    assert headers["anthropic-beta"] == "oauth-2025-04-20"
    assert [%{"text" => client}, %{"text" => "Be terse."}] = body["system"]
    assert client =~ "Claude Code"

    # tools carry input_schema, not parameters
    assert [%{"name" => "a", "input_schema" => %{"type" => "object"}}] = body["tools"]

    # the two tool results merge into a single user turn with two tool_result blocks
    user_results = Enum.find(body["messages"], &(&1["role"] == "user" and is_list(&1["content"])))
    assert length(user_results["content"]) == 2
    assert Enum.map(user_results["content"], & &1["type"]) == ["tool_result", "tool_result"]
    assert Enum.map(user_results["content"], & &1["tool_use_id"]) == ["t1", "t2"]

    assert body["max_tokens"] == 4096
  end

  test "an API key connection uses x-api-key and no client block", %{port: port} do
    model = %{oauth_model(port) | oauth: nil, api_key: "sk-ant-123"}
    {:ok, _} = Messages.chat(model, [%{"role" => "system", "content" => "S"}, %{"role" => "user", "content" => "hi"}], [])

    assert_received {:req, raw, headers}
    body = Jason.decode!(raw)

    assert headers["x-api-key"] == "sk-ant-123"
    refute Map.has_key?(headers, "authorization")
    # plain string system, no Claude Code spoof
    assert body["system"] == "S"
  end
end
