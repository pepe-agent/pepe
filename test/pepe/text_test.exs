defmodule Pepe.TextTest do
  use ExUnit.Case, async: true

  alias Pepe.Text

  test "truncate never splits a multi-byte character" do
    text = "aã" |> String.duplicate(10)

    for max <- 1..byte_size(text) do
      out = Text.truncate(text, max)
      assert String.valid?(out)
      assert byte_size(out) <= max
    end
  end

  test "truncate leaves short text alone" do
    assert Text.truncate("olá", 10) == "olá"
  end

  test "scrub replaces invalid bytes and leaves valid text alone" do
    assert Text.scrub("ok ã") == "ok ã"
    assert String.valid?(Text.scrub(<<"abc", 0xC3>>))
  end
end
