defmodule Pepe.Agent.MicroCompactionTest do
  @moduledoc """
  `Compaction.micro_compact/4`: instead of resummarizing the whole middle from scratch every
  turn (what `compact/3` does), it folds exactly the oldest not-yet-covered exchange into a
  running summary each call - pinned here: the fold order, that the cache actually
  progresses turn over turn, and that the caller's own message list is never touched (the
  `runtime.ex` `to_send` vs `messages` split depends on that).
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Compaction
  alias Pepe.Agent.MicroCompaction
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Each call returns a distinguishable summary ("FOLD 1", "FOLD 2", ...) so a test can prove
  # progression - a fixed response (like compaction_test.exs's SummaryPlug) can't tell "folded
  # the same exchange twice" apart from "folded the next one".
  defmodule NumberedFoldPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      n = Elixir.Agent.get_and_update(:mc_fold_count, fn c -> {c + 1, c + 1} end)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "FOLD #{n}"}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # A fixed response, unlike NumberedFoldPlug - for the one test that needs the SAME answer
  # regardless of how many times or in what order it's called.
  defmodule FixedPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "FIXED SUMMARY"}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Elixir.Agent.start_link(fn -> 0 end, name: :mc_fold_count)
    server = start_supervised!({Bandit, plug: NumberedFoldPlug, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = %Model{name: "m", base_url: "http://localhost:#{port}", api_key: "test", model: "id", context_window: 100}
    %{model: model}
  end

  # Same shape as compaction_test.exs's long_history/0: head (1 system) + middle (2
  # exchanges: q1/a1, q2/a2) + tail (1, the last user turn) at this window size.
  defp long_history do
    [
      Message.system("You are helpful."),
      Message.user("q1 " <> String.duplicate("a", 100)),
      Message.assistant("a1 " <> String.duplicate("b", 100)),
      Message.user("q2 " <> String.duplicate("c", 100)),
      Message.assistant("a2 " <> String.duplicate("d", 100)),
      Message.user("q3 " <> String.duplicate("e", 100))
    ]
  end

  test "under threshold is a no-op: unchanged, no cache written", %{model: model} do
    msgs = [Message.system("sys"), Message.user("hi"), Message.assistant("hello")]
    key = "sess-#{System.unique_integer([:positive])}"

    assert Compaction.micro_compact(msgs, %{model | context_window: 128_000}, nil, key) == msgs
    assert MicroCompaction.get(key) == nil
  end

  test "no session_key falls back to ordinary compact/3 (nothing to amortize across turns of)" do
    # A fixed-response mock, deliberately separate from the counting one `model` uses above -
    # this compares two independently computed results, so both calls need the same answer
    # regardless of order for the comparison to mean anything.
    server = start_supervised!({Bandit, plug: FixedPlug, port: 0, scheme: :http}, id: :fixed_server)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    fixed_model = %Model{name: "f", base_url: "http://localhost:#{port}", api_key: "test", model: "id", context_window: 100}

    msgs = long_history()
    assert Compaction.micro_compact(msgs, fixed_model, nil, nil) == Compaction.compact(msgs, fixed_model, nil)
  end

  test "the first call folds exactly the oldest exchange, leaving the rest verbatim", %{model: model} do
    key = "sess-#{System.unique_integer([:positive])}"
    msgs = long_history()

    compacted = Compaction.micro_compact(msgs, model, nil, key)

    assert [system, summary, q2, a2, tail] = compacted
    assert system == Message.system("You are helpful.")
    assert summary["role"] == "user"
    assert summary["content"] =~ "FOLD 1"
    assert q2 == Enum.at(msgs, 3)
    assert a2 == Enum.at(msgs, 4)
    assert tail == List.last(msgs)

    assert MicroCompaction.get(key) == {"FOLD 1", 1}

    # The caller's own list is untouched - the runtime's to_send/messages split depends on this.
    assert msgs == long_history()
  end

  test "a second call folds the NEXT oldest exchange, not the first one again", %{model: model} do
    key = "sess-#{System.unique_integer([:positive])}"
    msgs = long_history()

    _first = Compaction.micro_compact(msgs, model, nil, key)
    second = Compaction.micro_compact(msgs, model, nil, key)

    # Both exchanges are now covered, so nothing is left verbatim in the middle - just the
    # (now twice-folded) summary and the tail.
    assert [_system, summary, tail] = second
    assert summary["content"] =~ "FOLD 2"
    assert tail == List.last(msgs)

    assert MicroCompaction.get(key) == {"FOLD 2", 2}
    # Only two model calls total across both micro_compact/4 invocations - it never re-folds
    # an already-covered exchange.
    assert Elixir.Agent.get(:mc_fold_count, & &1) == 2
  end

  test "once every exchange is covered, a further call reuses the summary with no new model call", %{model: model} do
    key = "sess-#{System.unique_integer([:positive])}"
    msgs = long_history()

    Compaction.micro_compact(msgs, model, nil, key)
    Compaction.micro_compact(msgs, model, nil, key)
    third = Compaction.micro_compact(msgs, model, nil, key)

    assert [_system, summary, _tail] = third
    assert summary["content"] =~ "FOLD 2"
    assert Elixir.Agent.get(:mc_fold_count, & &1) == 2
  end

  test "a manual /compact clears the running-summary cache", %{model: model} do
    key = "sess-#{System.unique_integer([:positive])}"
    msgs = long_history()

    Compaction.micro_compact(msgs, model, nil, key)
    assert MicroCompaction.get(key) != nil

    MicroCompaction.clear(key)
    assert MicroCompaction.get(key) == nil
  end

  describe "exchanges/1 boundary shape (via micro_compact's fold order)" do
    test "an assistant tool-call turn stays attached to its result, inside the exchange it belongs to", %{model: model} do
      key = "sess-#{System.unique_integer([:positive])}"

      call = %{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}}

      msgs = [
        Message.system("sys" <> String.duplicate("s", 200)),
        Message.user("q1 " <> String.duplicate("a", 100)),
        Message.assistant_tool_calls("", [call]),
        Message.tool_result("c1", "bash", "ok " <> String.duplicate("o", 100)),
        Message.user("q2 " <> String.duplicate("c", 100)),
        Message.assistant("a2 " <> String.duplicate("d", 100)),
        Message.user("q3 " <> String.duplicate("e", 100))
      ]

      compacted = Compaction.micro_compact(msgs, model, nil, key)

      # The folded (first) exchange was q1 + its tool-call turn + the tool result - none of
      # that trio should show up verbatim in what comes back.
      refute Enum.any?(compacted, &(&1["role"] == "tool"))
    end
  end
end
