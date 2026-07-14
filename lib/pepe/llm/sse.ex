defmodule Pepe.LLM.SSE do
  @moduledoc """
  Server-Sent-Events framing shared by Pepe's three LLM adapters (`Pepe.LLM`,
  `Pepe.LLM.Messages`, `Pepe.LLM.Responses`) - each speaks a different event vocabulary once a
  `data:` line decodes to JSON, but splitting the raw byte stream into complete `data:` lines,
  buffering a trailing partial line across chunks, and flushing an un-terminated final line at
  stream end is byte-identical everywhere. This module owns that framing; each adapter supplies
  only `on_frame` (what a decoded JSON frame means to it, closed over its own `on_delta`) and
  keeps its own state map, which must carry a `:buffer` key (and a `:raw` key too, when using
  `collector/3`).
  """

  @doc """
  Feed one chunk of raw SSE bytes into `state`. Complete `data:` lines are JSON-decoded and
  passed to `on_frame.(decoded_map, state)` in order, threading the returned state through. The
  literal `data: [DONE]` line, blank lines, non-`data:` lines, and a line whose payload fails to
  decode as JSON are all a no-op - `on_frame` is never called for them (matching every adapter's
  prior behavior). Any leftover partial line is kept in `state.buffer` for the next chunk (or
  `flush/2` at stream end).
  """
  def consume(data, state, on_frame) do
    case String.split(state.buffer <> data, "\n") do
      [single] ->
        %{state | buffer: single}

      lines ->
        {complete, [partial]} = Enum.split(lines, -1)
        state = Enum.reduce(complete, %{state | buffer: ""}, &handle_line(&1, &2, on_frame))
        %{state | buffer: partial}
    end
  end

  @doc """
  Flush a final line left un-terminated in `state.buffer` (a truncated stream, or a provider
  that doesn't newline-end its last frame) so its content/tool/error is not silently dropped. An
  empty or still-incomplete (undecodable) buffer is a no-op.
  """
  def flush(state, on_frame) do
    case String.trim(state.buffer) do
      "" -> state
      _ -> handle_line(state.buffer, %{state | buffer: ""}, on_frame)
    end
  end

  defp handle_line(line, state, on_frame) do
    line = String.trim(line)

    cond do
      line == "" -> state
      not String.starts_with?(line, "data:") -> state
      true -> handle_data(String.trim(String.replace_prefix(line, "data:", "")), state, on_frame)
    end
  end

  defp handle_data("[DONE]", state, _on_frame), do: state

  defp handle_data(json, state, on_frame) do
    case Jason.decode(json) do
      {:ok, event} -> on_frame.(event, state)
      _ -> state
    end
  end

  @doc """
  A `Req` `into:` collector wired to `consume/3`. Accumulates raw bytes in `state.raw` (the only
  place a non-2xx error body can be read back from - `into:` leaves `resp.body` empty for a
  functional collector) alongside the parsed state, both under `resp.private[:pepe]`.

  `raw_cap` bounds `state.raw` to its first N bytes, keeping only the head as a large successful
  stream keeps flowing past it (a success body is never read from `raw` and would otherwise
  double the stream in memory); `nil` (the default) never truncates, for adapters whose error
  body can legitimately be the only thing worth keeping in full.
  """
  def collector(init, on_frame, raw_cap \\ nil) do
    fn {:data, data}, {req, resp} ->
      state = resp.private[:pepe] || init
      state = %{state | raw: accumulate_raw(state.raw, data, raw_cap)}
      state = consume(data, state, on_frame)
      {:cont, {req, %{resp | private: Map.put(resp.private, :pepe, state)}}}
    end
  end

  defp accumulate_raw(raw, data, nil), do: raw <> data

  defp accumulate_raw(raw, data, cap) do
    combined = raw <> data
    if byte_size(combined) > cap, do: binary_part(combined, 0, cap), else: combined
  end

  @doc """
  Classify a completed `Req.post` streaming result into the adapter's usual
  `{:ok, result} | {:error, reason}` shape. `finalize` turns the parsed state into a result once
  the stream is known to have succeeded (200..299); a non-2xx surfaces the raw body the collector
  captured under `state.raw`.
  """
  def result(req_result, init, on_frame, finalize) do
    case req_result do
      {:ok, %{status: status, private: %{pepe: state}}} when status in 200..299 ->
        {:ok, finalize.(flush(state, on_frame))}

      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, finalize.(resp.private[:pepe] || init)}

      {:ok, %{status: status} = resp} ->
        {:error, {:http_error, status, (resp.private[:pepe] || init).raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
