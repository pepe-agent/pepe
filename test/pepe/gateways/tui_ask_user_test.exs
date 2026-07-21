defmodule Pepe.Gateways.TUIAskUserTest do
  @moduledoc """
  `Pepe.Gateways.TUI.ask_user_fn/0` is the console's `ctx.ask_user` - an arrow-key menu
  over the tool's own choices, reusing `Pepe.TUI.select/2` exactly like `authorizer/0`
  already reuses it for the shared permission menu.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Pepe.Gateways.TUI

  test "picking a number returns that choice" do
    fun = TUI.ask_user_fn()

    result =
      capture_io([input: "2\n"], fn ->
        send(self(), {:picked, fun.("Coffee or tea?", ["Coffee", "Tea"])})
      end)

    assert result =~ "Coffee or tea?"
    assert_received {:picked, {:ok, "Tea"}}
  end
end
