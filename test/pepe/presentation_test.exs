defmodule Pepe.PresentationTest do
  @moduledoc """
  `Pepe.Presentation` is the provider-agnostic block schema `Pepe.Webhooks.Provider`'s
  optional `deliver_blocks/3` renders natively, and `to_text/1` is the fallback for a
  channel that doesn't implement it.
  """
  use ExUnit.Case, async: true

  alias Pepe.Presentation

  describe "valid?/1" do
    test "accepts a well-formed text block" do
      assert Presentation.valid?([%{"type" => "text", "text" => "hi"}])
    end

    test "accepts a well-formed table block" do
      assert Presentation.valid?([%{"type" => "table", "headers" => ["a", "b"], "rows" => [["1", "2"]]}])
    end

    test "accepts a well-formed buttons block" do
      assert Presentation.valid?([%{"type" => "buttons", "buttons" => [%{"label" => "Yes"}, %{"label" => "No", "value" => "no"}]}])
    end

    test "accepts multiple blocks together" do
      assert Presentation.valid?([
               %{"type" => "text", "text" => "Results:"},
               %{"type" => "table", "headers" => ["x"], "rows" => [["1"]]}
             ])
    end

    test "rejects a block with a missing required field" do
      refute Presentation.valid?([%{"type" => "text"}])
      refute Presentation.valid?([%{"type" => "table", "headers" => ["a"]}])
      refute Presentation.valid?([%{"type" => "buttons", "buttons" => [%{"value" => "no label"}]}])
    end

    test "rejects an unknown block type" do
      refute Presentation.valid?([%{"type" => "video", "url" => "x"}])
    end

    test "rejects a table with a non-string header or cell" do
      refute Presentation.valid?([%{"type" => "table", "headers" => [%{"bad" => true}], "rows" => [["1"]]}])
      refute Presentation.valid?([%{"type" => "table", "headers" => ["a"], "rows" => [[%{"bad" => true}]]}])
    end

    test "rejects a non-list" do
      refute Presentation.valid?(%{"type" => "text", "text" => "not a list"})
      refute Presentation.valid?("nope")
    end
  end

  describe "to_text/1 - the fallback for a channel with no deliver_blocks/3" do
    test "a text block passes through as-is" do
      assert Presentation.to_text([%{"type" => "text", "text" => "hello"}]) == "hello"
    end

    test "a table renders as a readable markdown-ish table" do
      text = Presentation.to_text([%{"type" => "table", "headers" => ["name", "age"], "rows" => [["zak", "9"], ["mia", "4"]]}])
      assert text == "name | age\n--- | ---\nzak | 9\nmia | 4"
    end

    test "buttons render as bracketed labels" do
      text = Presentation.to_text([%{"type" => "buttons", "buttons" => [%{"label" => "Yes"}, %{"label" => "No"}]}])
      assert text == "[Yes]\n[No]"
    end

    test "multiple blocks join with a blank line between them" do
      text =
        Presentation.to_text([
          %{"type" => "text", "text" => "Pick one:"},
          %{"type" => "buttons", "buttons" => [%{"label" => "A"}, %{"label" => "B"}]}
        ])

      assert text == "Pick one:\n\n[A]\n[B]"
    end

    test "an unrecognized block is silently dropped, not a crash" do
      text = Presentation.to_text([%{"type" => "text", "text" => "before"}, %{"type" => "mystery"}, %{"type" => "text", "text" => "after"}])
      assert text == "before\n\nafter"
    end
  end
end
