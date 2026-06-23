defmodule Pepe.LLMStreamErrorsTest do
  @moduledoc """
  Two ways an OpenAI-compatible SSE stream can quietly lose the truth:

    * a 200 stream that carries a top-level `error` frame instead of choices - it must surface as a
      failure (`finish_reason: "error"`), never as an empty successful answer, and carry the
      provider's own reason (`code: message`) so the log and trace say *why*; and
    * a final frame the provider (or a truncated connection) left without a trailing newline - it
      sits in the parser's buffer and would be dropped unless flushed at the end of the stream.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Model
  alias Pepe.LLM

  defmodule ErrorFramePlug do
    @behaviour Plug
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      body = ~s(data: {"error":{"code":"rate_limit_exceeded","message":"overloaded"}}\n\n)
      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  defmodule UnterminatedPlug do
    @behaviour Plug
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      # First frame is newline-terminated; the LAST content frame is NOT - it ends the body with no
      # trailing "\n", so a parser that only handles complete lines would leave "world" in its buffer.
      body =
        ~s(data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n) <>
          ~s(data: {"choices":[{"delta":{"content":"world"}}]})

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  defp serve(plug) do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, server} = Bandit.start_link(plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  test "a 200 stream carrying a top-level error frame finalizes as an error carrying the reason" do
    port = serve(ErrorFramePlug)
    model = %Model{name: "m", base_url: "http://127.0.0.1:#{port}/v1", api_key: "k", model: "gpt"}

    {:ok, res} = LLM.stream_chat(model, [%{"role" => "user", "content" => "go"}], fn _ -> :ok end)

    assert res.finish_reason == "error"
    # Not an empty success: the provider's own reason (code + message) is surfaced, so the runtime
    # can log/trace *why* instead of a bare `:provider_error`.
    assert res.content == "rate_limit_exceeded: overloaded"
  end

  test "a final frame left without a trailing newline is still captured" do
    port = serve(UnterminatedPlug)
    model = %Model{name: "m", base_url: "http://127.0.0.1:#{port}/v1", api_key: "k", model: "gpt"}

    {:ok, res} = LLM.stream_chat(model, [%{"role" => "user", "content" => "go"}], fn _ -> :ok end)

    assert res.content == "Hello world"
  end
end
