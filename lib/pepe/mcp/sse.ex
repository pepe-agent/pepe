defmodule Pepe.MCP.SSE do
  @moduledoc """
  Server-Sent-Events framing for the MCP transports.

  Deliberately not `Pepe.LLM.SSE`, which serves a different protocol: that one keeps only
  `data:` lines and only when they decode as JSON, because for a chat completion stream that
  is all a frame can be. MCP needs the two things it drops. The event **name** carries
  meaning - the legacy transport's whole bootstrap is one `event: endpoint` - and that
  event's payload is a bare URL, not JSON, so a JSON-only reader would discard exactly the
  message the connection cannot start without.

  `consume/2` takes raw bytes plus the leftover buffer and returns complete events and the
  new buffer, so a frame split across two network chunks survives the seam.
  """

  @doc """
  Split raw SSE bytes into complete events.

  Returns `{events, buffer}`, where each event is `%{event: name, data: payload}` - `name`
  defaults to `"message"` per the SSE spec, and multi-line `data:` fields are rejoined with
  newlines. Comment lines (`:` prefixed, which servers send as keep-alives) and fields we
  have no use for (`id:`, `retry:`) are dropped.
  """
  @spec consume(binary(), binary()) :: {[map()], binary()}
  def consume(data, buffer) do
    # \r\n is legal SSE and some servers (and proxies) use it. Normalising first means the
    # block split below has one delimiter to look for instead of four.
    combined = String.replace(buffer <> data, "\r\n", "\n")
    parts = String.split(combined, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    {complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1), rest}
  end

  @doc "Parse whatever complete event is left in a buffer at stream end, if any."
  @spec flush(binary()) :: [map()]
  def flush(buffer) do
    case String.trim(buffer) do
      "" -> []
      _ -> [parse_block(buffer)] |> Enum.reject(&is_nil/1)
    end
  end

  defp parse_block(block) do
    {name, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {name, data} ->
        case field(line) do
          {"event", value} -> {value, data}
          {"data", value} -> {name, [value | data]}
          _ -> {name, data}
        end
      end)

    case data do
      [] -> nil
      lines -> %{event: name || "message", data: lines |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  # "field: value" per the SSE grammar; one leading space after the colon is part of the
  # delimiter, not the value.
  defp field(line) do
    case String.split(line, ":", parts: 2) do
      # A line starting with ':' is a comment (keep-alive), not a field.
      ["", _] -> :comment
      [name, value] -> {name, String.replace_prefix(value, " ", "")}
      _ -> :comment
    end
  end
end
