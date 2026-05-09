defmodule Pepe.UsageSubscriptionTest do
  @moduledoc """
  A conversation run on a ChatGPT Plus or Claude Max login costs nothing per token, and is
  worth exactly the same to the client as one run on the paid API. The ledger has to hold
  both facts at once, and the reason it must is the day the subscription runs out: the same
  work falls through to the API, and the client's invoice cannot move.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Usage

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_usub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "worker", model: "api", system_prompt: "hi"})

    # Same provider, same price, same model. The only difference is how we pay for it.
    api = %Model{
      name: "api",
      base_url: "https://x/v1",
      model: "gpt",
      api_key: "sk-1",
      input_price: 10.0,
      output_price: 30.0
    }

    plan = %Model{
      name: "plan",
      base_url: "https://x/v1",
      model: "gpt",
      input_price: 10.0,
      output_price: 30.0,
      oauth: %{"provider" => "openai", "refresh" => "r"},
      monthly_cost: 20.0
    }

    Config.put_model(api)
    Config.put_model(plan)

    %{api: api, plan: plan}
  end

  # 1M in + 1M out at 10 / 30 per 1M = 40.00 on the API price list.
  defp usage, do: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000}

  defp month, do: Usage.summary(nil, :month)

  test "the client is billed the same either way", %{api: api, plan: plan} do
    # The same work, once on each. This is the month the subscription lapsed halfway through.
    Usage.record("worker", plan, usage())
    Usage.record("worker", api, usage())

    by_model = Map.new(month().by_model, &{&1.key, &1})

    # This is the whole point. A subscription is our supply arrangement, not the client's, so
    # the invoice does not so much as flinch when it runs out.
    assert by_model["plan"].billable == by_model["api"].billable
    assert by_model["plan"].billable == 40.0

    # What changed is what *we* paid, which is the number that was lying before.
    assert by_model["plan"].cost == 0.0
    assert by_model["api"].cost == 40.0
  end

  test "tokens served by a subscription cost us nothing, and the month's fee is counted once", %{plan: plan} do
    Usage.record("worker", plan, usage())
    Usage.record("worker", plan, usage())

    m = month()

    # Two calls, 80.00 of tokens at API prices. We paid none of it.
    assert m.totals.list == 80.0
    assert m.totals.cost == 0.0

    # We paid the subscription: once, not once per call.
    assert m.subscriptions == 20.0

    # And so the margin comes out right. The old ledger, pricing those tokens as if we had
    # bought them, would have reported a cost of 80.00 against 80.00 billed and called it
    # break-even, in a month where twenty dollars left the bank.
    assert m.margin == 60.0
  end

  test "an API connection still costs what it always did", %{api: api} do
    Usage.record("worker", api, usage())
    m = month()

    assert m.totals.list == 40.0
    assert m.totals.cost == 40.0
    assert m.subscriptions == 0.0
    assert m.margin == 0.0
  end

  test "a subscription we were never priced makes the margin optimistic, not wrong", %{plan: plan} do
    Config.put_model(%{plan | monthly_cost: nil})
    Usage.record("worker", Config.get_model("plan"), usage())

    m = month()

    # Nobody told Pepe what the subscription costs, so it counts zero rather than inventing a
    # number. The margin is then an upper bound, which is honest, and `pepe doctor` is where
    # it gets pointed out.
    assert m.subscriptions == 0.0
    assert m.margin == 40.0
  end

  test "switching a connection to an API key does not rewrite last month", %{plan: plan} do
    Usage.record("worker", plan, usage())

    # The operator cancels the subscription and puts an API key on the same connection.
    Config.put_model(%{plan | oauth: nil, api_key: "sk-2", monthly_cost: nil})

    m = month()

    # The entry remembers how it was actually paid for, because that was decided when it was
    # written. Reading the connection back would have retroactively charged us for tokens a
    # subscription had already covered.
    assert m.totals.cost == 0.0
    assert m.totals.billable == 40.0
  end

  test "recording by name alone still works and is not a subscription", %{api: _api} do
    # The old three-arg call with a bare name, as any surface that has not been updated makes
    # it. It must keep billing exactly as before rather than guessing.
    Usage.record("worker", "api", usage())
    m = month()

    assert m.totals.cost == 40.0
    assert m.subscriptions == 0.0
  end
end
