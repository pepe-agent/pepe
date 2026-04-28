defmodule Pepe.LLM.MessageTest do
  use ExUnit.Case, async: true

  alias Pepe.LLM.Message

  describe "sanitize_replay/1" do
    test "leaves a clean history untouched" do
      history = [
        Message.system("s"),
        Message.user("hi"),
        Message.assistant_tool_calls("", [%{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}}]),
        Message.tool_result("c1", "bash", "ok"),
        Message.assistant("done")
      ]

      assert Message.sanitize_replay(history) == history
    end

    test "drops a dangling assistant tool-call turn with no answer (crash mid-call)" do
      history = [
        Message.system("s"),
        Message.user("hi"),
        Message.assistant_tool_calls("", [%{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}}])
      ]

      assert Message.sanitize_replay(history) == [Message.system("s"), Message.user("hi")]
    end

    test "drops a partially-answered tool-call turn and its orphan results" do
      history = [
        Message.user("hi"),
        Message.assistant_tool_calls("", [
          %{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}},
          %{"id" => "c2", "function" => %{"name" => "read_file", "arguments" => "{}"}}
        ]),
        Message.tool_result("c1", "bash", "ok")
      ]

      # c2 was never answered, so the whole turn is dropped and c1's orphan result too.
      assert Message.sanitize_replay(history) == [Message.user("hi")]
    end

    test "keeps a fully-answered multi-call turn" do
      history = [
        Message.assistant_tool_calls("", [
          %{"id" => "c1", "function" => %{"name" => "bash", "arguments" => "{}"}},
          %{"id" => "c2", "function" => %{"name" => "read_file", "arguments" => "{}"}}
        ]),
        Message.tool_result("c1", "bash", "ok"),
        Message.tool_result("c2", "read_file", "data")
      ]

      assert Message.sanitize_replay(history) == history
    end
  end
end
