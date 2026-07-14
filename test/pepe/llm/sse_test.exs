defmodule Pepe.LLM.SSETest do
  @moduledoc """
  `Pepe.LLM.SSE` is the framing shared by all three LLM adapters - a bug here breaks streaming
  chat for every provider Pepe supports at once. These pin the framing itself (independent of
  any adapter's event vocabulary): a frame split across chunk boundaries (mid-line, mid-`data:`
  prefix), CRLF line endings, `[DONE]`, an undecodable frame, flushing an unterminated final
  line, and `collector/3`'s `raw_cap` truncation. Each adapter's own `*_test.exs` files cover
  what a decoded frame *means* to it; this file only covers getting a frame out of the byte
  stream in the first place.
  """
  use ExUnit.Case, async: true

  alias Pepe.LLM.SSE

  @init %{buffer: "", seen: [], raw: ""}

  # Collects every decoded frame it's called with, in order.
  defp collect(event, state), do: %{state | seen: state.seen ++ [event]}

  test "a complete frame in one chunk is decoded and handed to on_frame" do
    state = SSE.consume(~s(data: {"a":1}\n\n), @init, &collect/2)
    assert state.seen == [%{"a" => 1}]
    assert state.buffer == ""
  end

  test "a frame split mid-line across two chunks is only decoded once the line completes" do
    state = SSE.consume(~s(data: {"a":), @init, &collect/2)
    assert state.seen == []
    assert state.buffer == ~s(data: {"a":)

    state = SSE.consume(~s(1}\n\n), state, &collect/2)
    assert state.seen == [%{"a" => 1}]
  end

  test "a frame split mid \"data:\" prefix across two chunks is still recognized" do
    state = SSE.consume("da", @init, &collect/2)
    state = SSE.consume(~s(ta: {"a":1}\n\n), state, &collect/2)
    assert state.seen == [%{"a" => 1}]
  end

  test "CRLF line endings are handled the same as LF" do
    state = SSE.consume(~s(data: {"a":1}\r\n\r\n), @init, &collect/2)
    assert state.seen == [%{"a" => 1}]
  end

  test "multiple frames in one chunk are all decoded, in order" do
    state = SSE.consume(~s(data: {"a":1}\n\ndata: {"a":2}\n\n), @init, &collect/2)
    assert state.seen == [%{"a" => 1}, %{"a" => 2}]
  end

  test "\"[DONE]\" is a no-op - on_frame is never called for it" do
    state = SSE.consume(~s(data: [DONE]\n\n), @init, &collect/2)
    assert state.seen == []
  end

  test "a line that isn't a data: line is a no-op" do
    state = SSE.consume(~s(event: ping\n\n), @init, &collect/2)
    assert state.seen == []
  end

  test "a data: line whose payload fails to decode as JSON is a no-op, not a crash" do
    state = SSE.consume(~s(data: {not json\n\n), @init, &collect/2)
    assert state.seen == []
  end

  test "flush/2 decodes a final unterminated line left in the buffer" do
    state = SSE.consume(~s(data: {"a":1}), @init, &collect/2)
    assert state.seen == []

    state = SSE.flush(state, &collect/2)
    assert state.seen == [%{"a" => 1}]
  end

  test "flush/2 on an empty buffer is a no-op" do
    state = SSE.flush(@init, &collect/2)
    assert state.seen == []
  end

  test "collector/3 accumulates raw bytes and parsed state under resp.private[:pepe]" do
    on_frame = &collect/2
    collector = SSE.collector(@init, on_frame)

    {:cont, {req, resp}} = collector.({:data, ~s(data: {"a":1}\n\n)}, {:req, %{private: %{}}})
    assert req == :req
    assert resp.private[:pepe].seen == [%{"a" => 1}]
    assert resp.private[:pepe].raw == ~s(data: {"a":1}\n\n)
  end

  test "collector/3 with a raw_cap keeps only the head of the accumulated raw bytes" do
    on_frame = &collect/2
    collector = SSE.collector(@init, on_frame, 5)

    {:cont, {_req, resp}} = collector.({:data, "0123456789"}, {:req, %{private: %{}}})
    assert resp.private[:pepe].raw == "01234"

    {:cont, {_req, resp}} = collector.({:data, "more"}, {:req, resp})
    assert resp.private[:pepe].raw == "01234"
  end

  test "collector/3 with no raw_cap (the default) never truncates" do
    on_frame = &collect/2
    collector = SSE.collector(@init, on_frame)

    {:cont, {_req, resp}} = collector.({:data, String.duplicate("x", 10_000)}, {:req, %{private: %{}}})
    assert byte_size(resp.private[:pepe].raw) == 10_000
  end

  describe "result/4" do
    defp finalize(state), do: {:finalized, state.seen}

    test "a 2xx with parsed state flushes the buffer and finalizes" do
      state = %{@init | buffer: ~s(data: {"a":1})}
      req_result = {:ok, %{status: 200, private: %{pepe: state}}}

      assert SSE.result(req_result, @init, &collect/2, &finalize/1) ==
               {:ok, {:finalized, [%{"a" => 1}]}}
    end

    test "a 2xx with no data frames at all still finalizes, from init" do
      req_result = {:ok, %{status: 200, private: %{}}}
      assert SSE.result(req_result, @init, &collect/2, &finalize/1) == {:ok, {:finalized, []}}
    end

    test "a non-2xx surfaces the raw body the collector captured" do
      state = %{@init | raw: "rate limited"}
      req_result = {:ok, %{status: 429, private: %{pepe: state}}}

      assert SSE.result(req_result, @init, &collect/2, &finalize/1) ==
               {:error, {:http_error, 429, "rate limited"}}
    end

    test "a non-2xx with literally no data collected surfaces an empty raw body, not a crash" do
      req_result = {:ok, %{status: 500, private: %{}}}
      assert SSE.result(req_result, @init, &collect/2, &finalize/1) == {:error, {:http_error, 500, ""}}
    end

    test "a transport error passes through unchanged" do
      assert SSE.result({:error, :timeout}, @init, &collect/2, &finalize/1) == {:error, :timeout}
    end
  end
end
