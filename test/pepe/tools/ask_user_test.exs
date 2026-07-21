defmodule Pepe.Tools.AskUserTest do
  @moduledoc """
  `ask_user` itself is surface-agnostic: it just validates the question/choices and
  delegates to `ctx.ask_user`, exactly the same shape `Pepe.Permissions` already uses for
  `ctx.authorize`. The actual native rendering (Telegram buttons, the TUI menu, the
  dashboard picker) is covered per-surface elsewhere.
  """
  use ExUnit.Case, async: true

  alias Pepe.Tools.AskUser

  test "delegates to ctx.ask_user and returns its pick" do
    ctx = %{ask_user: fn "Coffee or tea?", ["Coffee", "Tea"] -> {:ok, "Tea"} end}
    args = %{"question" => "Coffee or tea?", "choices" => ["Coffee", "Tea"]}

    assert AskUser.run(args, ctx) == {:ok, "Tea"}
  end

  test "trims the question and each choice before handing them to ctx.ask_user" do
    ctx = %{ask_user: fn "Coffee or tea?", ["Coffee", "Tea"] -> {:ok, "Coffee"} end}
    args = %{"question" => "  Coffee or tea?  ", "choices" => [" Coffee ", " Tea "]}

    assert AskUser.run(args, ctx) == {:ok, "Coffee"}
  end

  test "a timeout comes back as a tool result, not an error, so the model can react" do
    ctx = %{ask_user: fn _q, _c -> :timeout end}
    args = %{"question" => "Pick one", "choices" => ["A", "B"]}

    assert {:ok, msg} = AskUser.run(args, ctx)
    assert msg =~ "didn't answer in time"
  end

  test "no ctx.ask_user (a non-interactive surface) fails outright, no hang" do
    args = %{"question" => "Pick one", "choices" => ["A", "B"]}

    assert {:error, msg} = AskUser.run(args, %{})
    assert msg =~ "no interactive user"
  end

  test "refuses a blank question" do
    ctx = %{ask_user: fn _q, _c -> {:ok, "A"} end}
    args = %{"question" => "   ", "choices" => ["A", "B"]}

    assert {:error, msg} = AskUser.run(args, ctx)
    assert msg =~ "blank"
  end

  test "refuses fewer than 2 choices" do
    ctx = %{ask_user: fn _q, _c -> {:ok, "A"} end}
    args = %{"question" => "Pick one", "choices" => ["Only one"]}

    assert {:error, msg} = AskUser.run(args, ctx)
    assert msg =~ "2 and 6"
  end

  test "refuses more than 6 choices" do
    ctx = %{ask_user: fn _q, _c -> {:ok, "A"} end}
    args = %{"question" => "Pick one", "choices" => Enum.map(1..7, &"opt#{&1}")}

    assert {:error, msg} = AskUser.run(args, ctx)
    assert msg =~ "2 and 6"
  end

  test "refuses a blank choice" do
    ctx = %{ask_user: fn _q, _c -> {:ok, "A"} end}
    args = %{"question" => "Pick one", "choices" => ["A", "  "]}

    assert {:error, msg} = AskUser.run(args, ctx)
    assert msg =~ "non-empty"
  end

  test "malformed args (missing choices) don't crash" do
    assert {:error, _} = AskUser.run(%{"question" => "Pick one"}, %{})
  end
end
