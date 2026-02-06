defmodule Cortex.Test.MockLLM do
  @moduledoc """
  A tiny OpenAI-compatible `/chat/completions` server for tests.

  Behaviour:
    * if the last message is a tool result, reply with a final assistant message;
    * otherwise, if the user asked to use a tool, reply with a tool call;
    * supports both streaming (SSE) and non-streaming responses.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    req = Jason.decode!(body)
    messages = req["messages"]
    stream? = req["stream"] == true
    last = List.last(messages)

    cond do
      last["role"] == "tool" ->
        respond(conn, stream?, %{content: "The file says: #{last["content"]}", tool_calls: nil})

      wants_tool?(messages) ->
        tool_call = %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => ~s({"path":"note.txt"})}
        }

        respond(conn, stream?, %{content: nil, tool_calls: [tool_call]})

      # A heartbeat pulse: stay silent, UNLESS the prompt was seeded with something
      # worth surfacing (used to test the "speaks up" path).
      user_content(messages) =~ "TRIGGER_SPEAK" ->
        respond(conn, stream?, %{content: "Something happened!", tool_calls: nil})

      user_content(messages) =~ "HEARTBEAT_OK" ->
        respond(conn, stream?, %{content: "HEARTBEAT_OK", tool_calls: nil})

      true ->
        respond(conn, stream?, %{content: "Hello from the mock!", tool_calls: nil})
    end
  end

  defp wants_tool?(messages) do
    Enum.any?(messages, fn m ->
      m["role"] == "user" and String.contains?(m["content"] || "", "read")
    end)
  end

  defp user_content(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "user"))
    |> Enum.map_join(" ", &(&1["content"] || ""))
  end

  defp respond(conn, false, %{content: content, tool_calls: tool_calls}) do
    message =
      %{"role" => "assistant", "content" => content}
      |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

    payload = %{
      "id" => "cmpl-1",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => if(tool_calls, do: "tool_calls", else: "stop")
        }
      ]
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  defp respond(conn, true, %{content: content, tool_calls: tool_calls}) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    chunks =
      cond do
        tool_calls ->
          [delta_chunk(%{"tool_calls" => tool_calls}), finish_chunk("tool_calls")]

        true ->
          words = String.split(content, " ")

          word_chunks =
            words
            |> Enum.with_index()
            |> Enum.map(fn {w, i} ->
              text = if i == 0, do: w, else: " " <> w
              delta_chunk(%{"content" => text})
            end)

          word_chunks ++ [finish_chunk("stop")]
      end

    Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c ->
      {:ok, _} = chunk(conn, c)
    end)

    conn
  end

  defp delta_chunk(delta) do
    payload = %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]}
    "data: #{Jason.encode!(payload)}\n\n"
  end

  defp finish_chunk(reason) do
    payload = %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}
    "data: #{Jason.encode!(payload)}\n\n"
  end
end
