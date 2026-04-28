defmodule Pepe.Agent.CompactionTest do
  use ExUnit.Case, async: true

  alias Pepe.Agent.Compaction
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  defp model(window \\ nil), do: %Model{name: "m", base_url: "x", model: "id", context_window: window}

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
end
