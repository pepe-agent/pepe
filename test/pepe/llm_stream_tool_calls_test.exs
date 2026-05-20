defmodule Pepe.LLMStreamToolCallsTest do
  @moduledoc """
  Assembling tool calls from an OpenAI-compatible SSE stream. OpenAI puts an `index` on every
  tool-call fragment; a conforming stream is the common path. But "any OpenAI-compatible provider
  works" is the project's promise, and some providers omit `index`. Keying every index-less delta
  to bucket 0 (the old behavior) concatenated distinct parallel calls into one garbled call - this
  pins that they stay separate.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Model
  alias Pepe.LLM

  defmodule Stream2Calls do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      # Two tool calls, streamed WITHOUT an `index` field, each split across fragments.
      events = [
        ~s({"choices":[{"delta":{"tool_calls":[{"id":"call_a","function":{"name":"get_a","arguments":""}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\\"x\\":"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"id":"call_b","function":{"name":"get_b","arguments":"{}"}}]}}]}),
        ~s({"choices":[{"delta":{},"finish_reason":"tool_calls"}]})
      ]

      body = Enum.map_join(events, "", fn e -> "data: " <> e <> "\n\n" end) <> "data: [DONE]\n\n"
      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, server} = Bandit.start_link(plug: Stream2Calls, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    {:ok, port: port}
  end

  test "index-less parallel tool calls assemble as separate calls, not one concatenated blob", %{port: port} do
    model = %Model{name: "m", base_url: "http://127.0.0.1:#{port}/v1", api_key: "k", model: "gpt"}

    {:ok, res} = LLM.stream_chat(model, [%{"role" => "user", "content" => "go"}], fn _ -> :ok end)

    assert [a, b] = res.tool_calls
    assert a["id"] == "call_a"
    assert a["function"]["name"] == "get_a"
    assert a["function"]["arguments"] == ~s({"x":1})
    assert b["id"] == "call_b"
    assert b["function"]["name"] == "get_b"
    assert b["function"]["arguments"] == "{}"
  end
end
