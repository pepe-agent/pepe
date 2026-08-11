defmodule Pepe.Usage.PrepaidTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Usage
  alias Pepe.Usage.Prepaid

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_prepaid_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_model(%Config.Model{name: "acme/p", model: "gpt-4o", input_price: 1.0, output_price: 0.0})
    Config.add_project("acme")
    :ok
  end

  test "balance/1 is nil for a project that's never been credited" do
    assert Prepaid.balance("acme") == nil
    refute Prepaid.exhausted?("acme")
  end

  test "credit/2 sets the balance, and it's unaffected by spend before the credit" do
    # $2 spent before any credit exists must not retroactively count against it.
    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 2_000_000, "completion_tokens" => 0})

    assert {:ok, 10.0} = Prepaid.credit("acme", 10.0)
    assert_in_delta Prepaid.balance("acme"), 10.0, 0.0001
  end

  test "balance/1 subtracts billable spend recorded after the credit" do
    {:ok, _} = Prepaid.credit("acme", 10.0)
    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 3_000_000, "completion_tokens" => 0})

    assert_in_delta Prepaid.balance("acme"), 7.0, 0.0001
  end

  test "a second credit settles first, so spend between credits isn't double-subtracted or lost" do
    {:ok, _} = Prepaid.credit("acme", 10.0)
    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 4_000_000, "completion_tokens" => 0})
    # Live balance right before the second credit: 10 - 4 = 6.
    assert {:ok, new_balance} = Prepaid.credit("acme", 5.0)
    assert_in_delta new_balance, 11.0, 0.0001
    assert_in_delta Prepaid.balance("acme"), 11.0, 0.0001

    # Spend after the second credit only ever subtracts once.
    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})
    assert_in_delta Prepaid.balance("acme"), 10.0, 0.0001
  end

  test "exhausted?/1 is true once spend brings the balance to zero or below" do
    {:ok, _} = Prepaid.credit("acme", 3.0)
    refute Prepaid.exhausted?("acme")

    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 3_000_000, "completion_tokens" => 0})
    assert Prepaid.exhausted?("acme")

    Usage.record("acme/x", "acme/p", %{"prompt_tokens" => 5_000_000, "completion_tokens" => 0})
    assert Prepaid.exhausted?("acme")
    assert Prepaid.balance("acme") < 0
  end

  test "credit/2 rejects a non-positive or non-numeric amount, balance untouched" do
    assert Prepaid.credit("acme", 0) == {:error, :invalid_amount}
    assert Prepaid.credit("acme", -5) == {:error, :invalid_amount}
    assert Prepaid.credit("acme", "10") == {:error, :invalid_amount}
    assert Prepaid.balance("acme") == nil
  end

  test "nil/empty project resolves to the default project slug, same balance either way" do
    {:ok, _} = Prepaid.credit(nil, 5.0)
    assert_in_delta Prepaid.balance(nil), 5.0, 0.0001
    assert_in_delta Prepaid.balance(""), 5.0, 0.0001
  end

  test "Pepe.Agent.Runtime refuses to run once a project's balance is exhausted" do
    Config.put_agent(%Config.Agent{name: "acme/bot", model: "acme/p", tools: []})
    {:ok, _} = Prepaid.credit("acme", 0.5)
    # 1M tokens at $1/M = $1, past the $0.50 balance.
    Usage.record("acme/bot", "acme/p", %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})

    assert {:error, :balance_exhausted} = Pepe.Agent.Runtime.converse(Config.get_agent("acme/bot"), "hi", [])
  end
end
