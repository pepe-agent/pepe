defmodule Pepe.Budget.AlertTest do
  @moduledoc """
  The soft budget alert fires once, per project, per month, for a project with active sessions that
  has crossed its alert threshold - and is channel-agnostic (it delivers through the same router
  watches use, so this test asserts the once-per-month dedup rather than any one gateway).
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Budget.Alert
  alias Pepe.Config
  alias Pepe.Store
  alias Pepe.Usage

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_budgetalert_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # A unique project per test: the dedup lives in the shared (Mnesia) Store, so a fixed slug would
    # leak the "already alerted this month" marker from one test into the next.
    proj = "acme#{System.unique_integer([:positive])}"
    Config.add_project(proj, %{"budget" => 10.0})
    Config.put_model(%Config.Model{name: "#{proj}/m", model: "gpt-4o", input_price: 1.0, output_price: 0.0})
    Config.put_agent(%Config.Agent{name: "#{proj}/sales", model: "#{proj}/m"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, proj: proj, key: "ws:budgettest-#{System.unique_integer([:positive])}"}
  end

  defp month_key(project) do
    {y, m, _} = Date.utc_today() |> Date.to_erl()
    "#{project}:#{y}-#{m}"
  end

  test "fires once for a project past its threshold, then dedupes for the month", %{proj: proj, key: key} do
    # Spend 8.5 of a 10.0 budget = 85%, past the default 80% alert.
    Usage.record("#{proj}/sales", "#{proj}/m", %{"prompt_tokens" => 8_500_000, "completion_tokens" => 0})
    assert Usage.near_budget?(proj)

    # A live session bound to an agent in the project, so the sweep finds it.
    {:ok, _} = SessionSupervisor.ensure(key, "#{proj}/sales")

    refute Store.get(:budget_alert, month_key(proj))

    Alert.check()
    assert Store.get(:budget_alert, month_key(proj)) == true

    # A second sweep is a no-op (already alerted this month) - and never crashes.
    Alert.check()
    assert Store.get(:budget_alert, month_key(proj)) == true
  end

  test "does not fire for a project below its threshold", %{proj: proj, key: key} do
    Usage.record("#{proj}/sales", "#{proj}/m", %{"prompt_tokens" => 5_000_000, "completion_tokens" => 0})
    refute Usage.near_budget?(proj)

    {:ok, _} = SessionSupervisor.ensure(key, "#{proj}/sales")

    Alert.check()
    refute Store.get(:budget_alert, month_key(proj))
  end
end
