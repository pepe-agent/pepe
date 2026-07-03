defmodule Pepe.LLM.CacheUsageTest do
  @moduledoc """
  Each streaming adapter surfaces cache-read input as a `cached_tokens` field on the usage map, a
  subset of `prompt_tokens`, so the billing ledger can price it at the cheaper cache rate. Anthropic
  reports cache-read separately from `input_tokens` (so prompt_tokens = input + cache_read); the
  Responses API already folds cached into `input_tokens`.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Pepe.Config.Model
  alias Pepe.LLM.Messages
  alias Pepe.LLM.Responses

  defp start(plug) do
    {:ok, server} = Bandit.start_link(plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defmodule AnthropicCache do
    import Plug.Conn
    def init(o), do: o

    def call(conn, _) do
      events = [
        ~s({"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":1}}}),
        ~s({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        ~s({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}),
        ~s({"type":"content_block_stop","index":0}),
        ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}),
        ~s({"type":"message_stop"})
      ]

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, Pepe.LLM.CacheUsageTest.sse_public(events))
    end
  end

  defmodule ResponsesCache do
    import Plug.Conn
    def init(o), do: o

    def call(conn, _) do
      events = [
        ~s({"type":"response.output_text.delta","delta":"ok"}),
        ~s({"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":5,"input_tokens_details":{"cached_tokens":90}}}})
      ]

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, Pepe.LLM.CacheUsageTest.sse_public(events))
    end
  end

  # exposed so the plug modules (compiled separately) can reuse the encoder
  def sse_public(events), do: Enum.map_join(events, "", &("data: " <> &1 <> "\n\n"))

  test "anthropic: prompt_tokens is input + cache_read, cached_tokens is the cache-read portion" do
    port = start(AnthropicCache)
    model = %Model{name: "c", base_url: "http://127.0.0.1:#{port}/v1", api: "anthropic-messages", api_key: "x", model: "claude"}

    {:ok, res} = Messages.stream_chat(model, [%{"role" => "user", "content" => "hi"}], fn _ -> :ok end)

    assert res.usage["prompt_tokens"] == 100
    assert res.usage["cached_tokens"] == 90
    assert res.usage["completion_tokens"] == 5
  end

  test "responses: cached_tokens is surfaced from input_tokens_details" do
    port = start(ResponsesCache)
    model = %Model{name: "r", base_url: "http://127.0.0.1:#{port}/codex", api: "openai-responses", api_key: "x", model: "gpt-5"}

    {:ok, res} = Responses.stream_chat(model, [%{"role" => "user", "content" => "hi"}], fn _ -> :ok end)

    assert res.usage["prompt_tokens"] == 100
    assert res.usage["cached_tokens"] == 90
  end
end
