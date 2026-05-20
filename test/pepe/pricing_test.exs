defmodule Pepe.PricingTest do
  @moduledoc """
  Pricing is pure money math that feeds every usage/billing figure, and it was only exercised in
  passing by the usage tests. Its two load-bearing pieces are pinned here: `cost/4` (the currency
  math) and `lookup/2` (the layered cache-over-seed, longest-substring match).
  """
  use ExUnit.Case, async: true

  alias Pepe.Pricing

  describe "cost/4" do
    test "sums input and output at per-1M rates" do
      # 1M in @ 2.0 + 1M out @ 6.0 = 8.0
      assert Pricing.cost(1_000_000, 1_000_000, 2.0, 6.0) == 8.0
      # half a million out only
      assert Pricing.cost(0, 500_000, 2.0, 6.0) == 3.0
    end

    test "an unpriced side contributes nothing (nil price -> 0.0), never crashes" do
      assert Pricing.cost(1_000_000, 1_000_000, nil, nil) == 0.0
      assert Pricing.cost(1_000_000, 1_000_000, 2.0, nil) == 2.0
    end
  end

  describe "lookup/2 (cache over seed, longest match wins)" do
    test "a cache entry is used, as a %{in, out} map" do
      cache = %{"acme-model" => %{"in" => 5, "out" => 15}}
      assert Pricing.lookup("acme-model", cache) == {5, 15}
    end

    test "the longest key that is a substring of the id wins" do
      cache = %{"gpt" => %{"in" => 1, "out" => 2}, "gpt-4o" => %{"in" => 5, "out" => 15}}
      # "gpt-4o-mini" contains both "gpt" and "gpt-4o"; the longer key wins.
      assert Pricing.lookup("gpt-4o-mini", cache) == {5, 15}
    end

    test "a nil id, or an id matching nothing, is nil" do
      assert Pricing.lookup(nil, %{}) == nil
      assert Pricing.lookup("totally-unknown-zzz-999", %{}) == nil
    end
  end
end
