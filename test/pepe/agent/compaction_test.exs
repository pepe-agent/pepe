defmodule Pepe.Agent.CompactionTest do
  use ExUnit.Case, async: true

  alias Pepe.Agent.Compaction
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # The summarizer the compaction calls, with the misbehaviors it has to survive. A 4xx
  # stands in for "the call failed": the client does not retry it, so the failure path is
  # exercised at once instead of several seconds later.
  defmodule SummaryPlug do
    @moduledoc false
    import Plug.Conn

    def init(mode), do: mode

    def call(conn, mode) do
      {:ok, _body, conn} = read_body(conn)

      case mode do
        :summary -> ok(conn, "SUMMARY: they agreed to ship on Friday.")
        :empty -> ok(conn, "")
        :no_content -> ok(conn, nil)
        :failing -> conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error": "no"}))
      end
    end

    defp ok(conn, content) do
      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  defp model(window \\ nil), do: %Model{name: "m", base_url: "x", model: "id", context_window: window}

  # A model pointed at a live summarizer behaving as `mode`. The tiny context window is
  # what puts the history over the compaction threshold without needing a huge fixture.
  defp mock_model(mode) do
    server = start_supervised!({Bandit, plug: {SummaryPlug, mode}, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    %Model{name: "m", base_url: "http://localhost:#{port}", api_key: "test", model: "id", context_window: 100}
  end

  # A history that splits into head (1 system) + middle (4) + tail (1) for a 100-token
  # window: each turn is big enough that only the last one fits the verbatim tail.
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

  test "estimate_tokens grows with content and is roughly bytes/4" do
    small = [Message.user(String.duplicate("x", 40))]
    big = [Message.user(String.duplicate("x", 4000))]

    assert Compaction.estimate_tokens(small) < Compaction.estimate_tokens(big)
    assert_in_delta Compaction.estimate_tokens(big), 1000, 50
  end

  test "window falls back to a default when the model doesn't declare one" do
    assert Compaction.window(model()) == 128_000
    assert Compaction.window(model(8000)) == 8000
  end

  test "needs? only when the estimate passes the window fraction" do
    tiny = [Message.user("hi")]
    refute Compaction.needs?(tiny, model(8000))

    huge = [Message.user(String.duplicate("x", 40_000))]
    assert Compaction.needs?(huge, model(8000))
  end

  describe "split/2" do
    test "head is the leading system messages; tail keeps the most recent" do
      msgs = [
        Message.system("sys"),
        Message.user("q1"),
        Message.assistant("a1"),
        Message.user("q2"),
        Message.assistant("a2")
      ]

      {head, middle, tail} = Compaction.split(msgs, 12)

      assert head == [Message.system("sys")]
      assert List.last(tail) == Message.assistant("a2")
      assert head ++ middle ++ tail == msgs
    end

    test "the tail never begins with an orphan tool result" do
      msgs = [
        Message.system("sys"),
        Message.assistant_tool_calls("", [%{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}}]),
        Message.tool_result("c1", "bash", "ok"),
        Message.user("next")
      ]

      # A tiny keep budget would land the boundary on the tool result; it must be dropped.
      {_head, _middle, tail} = Compaction.split(msgs, 1)
      refute match?([%{"role" => "tool"} | _], tail)
    end
  end

  test "compact is a no-op (no model call) when the history fits the window" do
    msgs = [Message.system("sys"), Message.user("hi"), Message.assistant("hello")]
    assert Compaction.compact(msgs, model(128_000)) == msgs
  end

  test "compact_now errors cleanly with no model" do
    assert Compaction.compact_now([Message.user("hi")], nil) == {:error, :no_model}
  end

  test "compact_now reports nothing to compact on a short history (no model call)" do
    msgs = [Message.system("sys"), Message.user("hi"), Message.assistant("hello")]
    assert {:ok, ^msgs, "nothing to compact yet"} = Compaction.compact_now(msgs, model(128_000))
  end

  test "compact is a no-op when there's too little middle to bother summarizing" do
    # Over the window, but almost everything is protected head/tail: nothing to summarize.
    msgs = [Message.system(String.duplicate("s", 40_000)), Message.user("hi")]
    assert Compaction.compact(msgs, model(8000)) == msgs
  end

  test "compact_now replaces the middle with the model's summary, keeping head and tail" do
    msgs = long_history()
    {head, middle, tail} = Compaction.split(msgs, 30)
    assert [_, _, _, _] = middle

    assert {:ok, compacted, "SUMMARY: they agreed to ship on Friday."} =
             Compaction.compact_now(msgs, mock_model(:summary))

    [kept_head] = head
    assert [^kept_head, summary | ^tail] = compacted

    # The condensed middle comes back as a single system message that says it is one.
    assert summary["role"] == "system"
    assert summary["content"] =~ "older turns were condensed"
    assert summary["content"] =~ "ship on Friday"

    # And the point of the exercise: it is smaller than what went in.
    assert Compaction.estimate_tokens(compacted) < Compaction.estimate_tokens(msgs)
  end

  describe "compact_now surfaces a summarizer that didn't deliver" do
    test "an empty summary is not a summary" do
      assert {:error, :empty_summary} = Compaction.compact_now(long_history(), mock_model(:empty))
    end

    test "a reply with no content at all is not a summary either" do
      assert {:error, :empty_summary} = Compaction.compact_now(long_history(), mock_model(:no_content))
    end

    test "a failed call is reported with its reason" do
      assert {:error, {:http_error, 400, _body}} = Compaction.compact_now(long_history(), mock_model(:failing))
    end
  end

  test "a failing summarizer never breaks the request: compact returns the history untouched" do
    msgs = long_history()
    model = mock_model(:failing)

    # The history is over the threshold, so compaction really is attempted...
    assert Compaction.needs?(msgs, model)

    # ...and when it fails, the caller still gets its messages, intact and unraised.
    assert Compaction.compact(msgs, model) == msgs
  end
end
