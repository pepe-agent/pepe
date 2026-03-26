defmodule Pepe.LLM.ResponsesTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Model
  alias Pepe.LLM.Responses

  defmodule FakeResponses do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      events = [
        ~s({"type":"response.output_item.added","item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"get_weather","arguments":""}}),
        ~s({"type":"response.function_call_arguments.delta","item_id":"item_1","delta":"{\\"city\\":"}),
        ~s({"type":"response.function_call_arguments.done","item_id":"item_1","arguments":"{\\"city\\":\\"SF\\"}"}),
        ~s({"type":"response.output_text.delta","delta":"Hello "}),
        ~s({"type":"response.output_text.delta","delta":"world"}),
        ~s({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}})
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
      Bandit.start_link(plug: FakeResponses, scheme: :http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, port: port}
  end

  test "assembles assistant text and tool calls from the Responses SSE stream", %{port: port} do
    model = %Model{
      name: "codex",
      base_url: "http://127.0.0.1:#{port}/codex",
      api: "openai-responses",
      api_key: "not-a-jwt",
      model: "gpt-5-codex"
    }

    {parent, ref} = {self(), make_ref()}
    on_delta = fn text -> send(parent, {ref, text}) end

    {:ok, res} =
      Responses.stream_chat(model, [%{"role" => "user", "content" => "weather?"}], on_delta)

    # assistant text deltas streamed and assembled
    assert_received {^ref, "Hello "}
    assert_received {^ref, "world"}
    assert res.content == "Hello world"

    # the function call is translated back into Chat-Completions shape
    assert [call] = res.tool_calls
    assert call["id"] == "call_1"
    assert call["type"] == "function"
    assert call["function"]["name"] == "get_weather"
    assert call["function"]["arguments"] == ~s({"city":"SF"})

    # a turn with tool calls reports tool_calls so the runtime keeps looping
    assert res.finish_reason == "tool_calls"
    # usage is normalized to the canonical prompt/completion key names
    assert res.usage["prompt_tokens"] == 5
  end

  defmodule FakeRefusal do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      events = [
        ~s({"type":"response.refusal.delta","delta":"I can't help "}),
        ~s({"type":"response.refusal.delta","delta":"with that."}),
        ~s({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":9,"output_tokens":4}}})
      ]

      body = Enum.map_join(events, "", fn e -> "data: " <> e <> "\n\n" end)
      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  test "a refusal surfaces as assistant text instead of an empty reply" do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, server} = Bandit.start_link(plug: FakeRefusal, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    model = %Model{name: "codex", base_url: "http://127.0.0.1:#{port}/codex", api: "openai-responses", api_key: "x", model: "gpt-5.5"}

    {:ok, res} = Responses.stream_chat(model, [%{"role" => "user", "content" => "do something bad"}], fn _ -> :ok end)

    assert res.content == "I can't help with that."
    assert res.tool_calls == []
  end
end
