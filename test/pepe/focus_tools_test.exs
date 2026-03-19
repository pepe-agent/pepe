defmodule Pepe.FocusToolsTest do
  use ExUnit.Case, async: false

  alias Pepe.Session.Focus
  alias Pepe.Tools.Goal
  alias Pepe.Tools.Plan

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    key = "test:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Focus.clear_goal(key)
      Focus.clear_plan(key)
    end)

    %{ctx: %{session_key: key}, key: key}
  end

  test "goal set/show/status/clear round-trip", %{ctx: ctx, key: key} do
    assert {:ok, out} = Goal.run(%{"action" => "set", "objective" => "ship the release", "budget_tokens" => 50_000}, ctx)
    assert out =~ "ship the release"
    assert Focus.get_goal(key)["status"] == "active"
    assert Focus.get_goal(key)["budget_tokens"] == 50_000

    assert {:ok, out} = Goal.run(%{"action" => "status", "status" => "complete", "note" => "shipped"}, ctx)
    assert out =~ "complete"
    assert Focus.get_goal(key)["status"] == "complete"
    assert Focus.get_goal(key)["note"] == "shipped"

    assert {:ok, shown} = Goal.run(%{"action" => "show"}, ctx)
    assert shown =~ "ship the release"

    assert {:ok, _} = Goal.run(%{"action" => "clear"}, ctx)
    assert Focus.get_goal(key) == nil
  end

  test "goal set requires an objective, and status must be valid", %{ctx: ctx} do
    assert {:error, _} = Goal.run(%{"action" => "set"}, ctx)
    Goal.run(%{"action" => "set", "objective" => "x"}, ctx)
    assert {:error, _} = Goal.run(%{"action" => "status", "status" => "bogus"}, ctx)
  end

  test "goal without a session errors" do
    assert {:error, _} = Goal.run(%{"action" => "show"}, %{})
  end

  test "update_plan sets, renders progress, and clears", %{ctx: ctx, key: key} do
    steps = [
      %{"title" => "design", "status" => "done"},
      %{"title" => "build", "status" => "in_progress"},
      %{"title" => "ship"}
    ]

    assert {:ok, out} = Plan.run(%{"steps" => steps}, ctx)
    assert out =~ "1/3 done"
    assert out =~ "[x] design"
    assert out =~ "[~] build"
    assert out =~ "[ ] ship"
    assert length(Focus.get_plan(key)) == 3

    assert {:ok, "Plan cleared."} = Plan.run(%{"steps" => []}, ctx)
    assert Focus.get_plan(key) == nil
  end

  test "update_plan drops malformed steps and defaults status", %{ctx: ctx, key: key} do
    steps = [%{"title" => "ok"}, %{"nope" => "x"}, %{"title" => "", "status" => "done"}]
    assert {:ok, _} = Plan.run(%{"steps" => steps}, ctx)

    plan = Focus.get_plan(key)
    assert plan == [%{"title" => "ok", "status" => "pending"}]
  end

  test "plan without a session errors" do
    assert {:error, _} = Plan.run(%{"steps" => [%{"title" => "x"}]}, %{})
  end
end
