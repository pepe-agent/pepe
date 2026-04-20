defmodule Pepe.TUITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Pepe.TUI

  # select/multiselect are always the paginated numbered menu now, driven by
  # typed input - exactly what CaptureIO's :input feeds here.
  defp run(lines, fun) do
    capture_io([input: Enum.join(lines, "\n") <> "\n"], fun)
  end

  describe "select/2" do
    test "a single item is returned with no prompt at all" do
      out = run([], fn -> send(self(), {:result, TUI.select(["only"])}) end)
      assert out == ""
      assert_received {:result, "only"}
    end

    test "a short list (one page) - pick by number, no pagination shown" do
      items = ["alpha", "beta", "gamma"]

      out =
        run(["2"], fn ->
          send(self(), {:result, TUI.select(items, label: "Pick:")})
        end)

      assert out =~ "1. alpha"
      assert out =~ "3. gamma"
      refute out =~ "page"
      assert_received {:result, "beta"}
    end

    test "invalid input is rejected and reprompts" do
      items = ["alpha", "beta", "gamma"]

      out =
        run(["xyz", "2"], fn ->
          send(self(), {:result, TUI.select(items)})
        end)

      assert out =~ "1 to 3"
      assert_received {:result, "beta"}
    end

    test "a bare Enter is a no-op (does NOT advance the page)" do
      items = for i <- 1..250, do: "item-#{i}"

      # blank (no-op, stay on page 1), then pick 5 which is on page 1.
      out = run(["", "5"], fn -> send(self(), {:result, TUI.select(items)}) end)

      assert out =~ "page 1/13"
      refute out =~ "page 2/13"
      assert_received {:result, "item-5"}
    end

    test "'n' pages forward, 'p' pages back, then pick a later-page item" do
      items = for i <- 1..250, do: "item-#{i}"

      out =
        run(["n", "p", "n", "37"], fn ->
          send(self(), {:result, TUI.select(items, label: "Pick one:")})
        end)

      assert out =~ "page 1/13"
      assert out =~ "page 2/13"
      assert out =~ "37. item-37"
      assert_received {:result, "item-37"}
    end

    test "'n' wraps from the last page back to the first" do
      items = for i <- 1..25, do: "item-#{i}"
      # 2 pages; n -> page 2, n -> wraps to page 1, then pick 5 (on page 1).
      out = run(["n", "n", "5"], fn -> send(self(), {:result, TUI.select(items)}) end)

      assert out =~ "page 1/2"
      assert_received {:result, "item-5"}
    end
  end

  describe "multiselect/2" do
    test "an empty list returns [] immediately with no prompt" do
      out = run([], fn -> send(self(), {:result, TUI.multiselect([])}) end)
      assert out == ""
      assert_received {:result, []}
    end

    test "toggling by number, paging with n/p, then Enter finishes" do
      items = for i <- 1..50, do: "item-#{i}"

      out =
        run(["3 7", "n", "p", "15", ""], fn ->
          send(self(), {:result, TUI.multiselect(items, label: "Pick some:")})
        end)

      assert out =~ "[x] 3. item-3"
      assert out =~ "marked"
      assert_received {:result, ["item-3", "item-7", "item-15"]}
    end

    test "toggling the same number twice deselects it; 'd' finishes" do
      items = ["alpha", "beta", "gamma"]

      out =
        run(["1 2", "1", "d"], fn ->
          send(self(), {:result, TUI.multiselect(items)})
        end)

      assert out =~ "1. alpha"
      assert_received {:result, ["beta"]}
    end

    test "a bare Enter finishes the multiselect with the current selection" do
      items = ["alpha", "beta", "gamma"]
      run(["2", ""], fn -> send(self(), {:result, TUI.multiselect(items)}) end)
      assert_received {:result, ["beta"]}
    end
  end
end
