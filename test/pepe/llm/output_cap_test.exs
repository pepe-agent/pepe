defmodule Pepe.LLM.OutputCapTest do
  @moduledoc """
  `available/1` is the whole predicate: a number means "we can recover from this, and here
  is the ceiling", `nil` means "not our case". Both halves are load-bearing, so both are
  pinned - a false positive would shrink the answer of a request that was never refused for
  that reason, and a false negative puts the turn back in the loop this exists to break.
  """
  use ExUnit.Case, async: true

  alias Pepe.LLM.OutputCap

  describe "the provider says what is left" do
    test "anthropic states it outright" do
      body = %{
        "error" => %{
          "message" => "max_tokens: 32768 > context_window: 200000 - input_tokens: 190000 = available_tokens: 10000"
        }
      }

      assert OutputCap.available(body) == 10_000
    end

    test "the openai dialect states the window and the input, and we subtract" do
      body = %{
        "error" => %{
          "message" =>
            "This model's maximum context length is 8192 tokens. However, you requested 8500 " <>
              "tokens (7500 in the messages, 1000 in the completion). Please reduce the length."
        }
      }

      assert OutputCap.available(body) == 692
    end

    test "openrouter splits the input in two, and both halves count" do
      body =
        "maximum context length is 32768 tokens. However, you requested 40000 " <>
          "(20000 of text input, 4000 of tool input, 16000 in the output)"

      # 32768 - (20000 + 4000). Counting only the first would have left 12768, which is
      # 4000 tokens of tool schema too many, and the retry would be refused all over again.
      assert OutputCap.available(body) == 8768
    end

    test "qwen states the model's output range, which is a ceiling and not the room left" do
      assert OutputCap.available("Range of max_tokens should be [1, 65536]") == 65_536
    end
  end

  describe "not our case" do
    test "a genuine input overflow says nothing" do
      # The input alone exceeds the window. There is no reservation to shrink; this one
      # really does need the conversation condensed, and claiming it would send the turn
      # down the wrong recovery path.
      body =
        "This model's maximum context length is 8192 tokens. However, you requested 9000 " <>
          "tokens (8500 in the messages, 500 in the completion)."

      assert OutputCap.available(body) == nil
    end

    test "an unrelated error says nothing" do
      assert OutputCap.available(%{"error" => %{"message" => "Incorrect API key provided"}}) == nil
      assert OutputCap.available("Internal server error") == nil
      assert OutputCap.available(nil) == nil
      assert OutputCap.available(%{"weird" => ["shape"]}) == nil
    end
  end
end
