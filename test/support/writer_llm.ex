defmodule Pepe.Test.WriterLLM do
  @moduledoc """
  A tiny OpenAI-compatible `/chat/completions` server for tests that need a turn to change a
  file, so the checkpoint store has something to put back.

    * a message `WRITE <name> <content>` makes the model call `write_file` with that path and
      content, then say `wrote it` once the tool result comes back;
    * anything else is a plain `sure thing`;
    * both are served streaming (SSE) or not, whichever the caller asked for.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    req = Jason.decode!(body)
    last = req["messages"] |> List.last()

    case {last["role"], String.split(to_string(last["content"]), " ", parts: 3)} do
      {"user", ["WRITE", name, content]} -> respond(conn, req["stream"] == true, nil, write_call(name, content))
      {"tool", _} -> respond(conn, req["stream"] == true, "wrote it", nil)
      _ -> respond(conn, req["stream"] == true, "sure thing", nil)
    end
  end

  defp write_call(name, content) do
    args = Jason.encode!(%{"path" => name, "content" => content})
    [%{"id" => "call_1", "type" => "function", "function" => %{"name" => "write_file", "arguments" => args}}]
  end

  defp respond(conn, false, content, tool_calls) do
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

  defp respond(conn, true, content, tool_calls) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    chunks =
      if tool_calls do
        [sse(%{"tool_calls" => Enum.with_index(tool_calls, &Map.put(&1, "index", &2))}, nil), sse(%{}, "tool_calls")]
      else
        [sse(%{"content" => content}, nil), sse(%{}, "stop")]
      end

    Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c -> {:ok, _} = Plug.Conn.chunk(conn, c) end)
    conn
  end

  defp sse(delta, finish) do
    "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]})}\n\n"
  end
end
