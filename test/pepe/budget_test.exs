defmodule Pepe.BudgetTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Usage

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_budget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.add_company("acme", %{"budget" => 0.01})
    Config.put_model(%Model{name: "m", base_url: "http://x/v1", model: "m", input_price: 1.0, output_price: 1.0})
    Config.put_agent(%Agent{name: "acme/bot", model: "m", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "company_budget reads the cap; root has none" do
    assert Config.company_budget("acme") == 0.01
    assert Config.company_budget(nil) == nil
    assert Config.company_budget("nope") == nil
  end

  test "over_budget? is false with no spend and true once the month's billable reaches the cap" do
    refute Usage.over_budget?("acme")
    refute Usage.over_budget?(nil)

    # ~0.20 billable at 1.0/1M-token prices, well over the 0.01 cap
    Usage.record("acme/bot", "m", %{"prompt_tokens" => 100_000, "completion_tokens" => 100_000})

    assert Usage.over_budget?("acme")
    assert Usage.month_to_date("acme") > 0.01
  end

  test "the runtime refuses a run for a company over budget (pre-flight, no model call)" do
    agent = Config.get_agent("acme/bot")
    Usage.record("acme/bot", "m", %{"prompt_tokens" => 100_000, "completion_tokens" => 100_000})

    assert {:error, :budget_exceeded} = Runtime.run(agent, [])
  end

  test "a company with no cap is never blocked" do
    Config.add_company("free", %{})
    Config.put_agent(%Agent{name: "free/bot", model: "m", tools: []})
    Usage.record("free/bot", "m", %{"prompt_tokens" => 500_000, "completion_tokens" => 500_000})

    refute Usage.over_budget?("free")
  end
end
