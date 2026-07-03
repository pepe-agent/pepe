defmodule Pepe.UsageTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Pricing
  alias Pepe.Usage

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_usage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  describe "pricing" do
    test "seed lookup matches the longest id substring" do
      assert Pricing.lookup("gpt-4o-mini") == {0.15, 0.60}
      # dated snapshot inherits its family's price via longest-prefix match
      assert Pricing.lookup("gpt-4o-2024-08-06") == {2.50, 10.00}
      assert Pricing.lookup("totally-unknown-model") == nil
    end

    test "cost is tokens × per-1M price, 0 when unpriced" do
      assert Pricing.cost(1_000_000, 500_000, 2.5, 10.0) == 2.5 + 5.0
      assert Pricing.cost(1_000_000, 500_000, nil, nil) == 0.0
    end

    test "the manual cache layer overrides the seed" do
      cache = %{"gpt-4o" => %{"in" => 1.0, "out" => 2.0}}
      assert Pricing.lookup("gpt-4o", cache) == {1.0, 2.0}
      # falls through to seed when the cache misses
      assert Pricing.lookup("claude-3-opus", cache) == {15.00, 75.00}
    end

    test "cost/6 prices the cached portion of input at the cache rate" do
      # 1M input, 800k of it cache-read; fresh 200k×2.5 + cached 800k×0.25 + out 500k×10 = 5.7
      assert_in_delta Pricing.cost(1_000_000, 500_000, 800_000, 2.5, 10.0, 0.25), 5.7, 0.0001
      # no cache rate known -> cached priced as normal input, exactly the old cost/4
      assert Pricing.cost(1_000_000, 0, 800_000, 2.5, 10.0, nil) == Pricing.cost(1_000_000, 0, 2.5, 10.0)
      # cached never exceeds input
      assert Pricing.cost(1_000_000, 0, 9_000_000, 2.5, 10.0, 0.0) == 0.0
    end

    test "cached_rate reads the cache-read price from the price book" do
      cache = %{"gpt-4o" => %{"in" => 2.5, "out" => 10.0, "cached" => 1.25}}
      assert Pricing.cached_rate("gpt-4o", cache) == 1.25
      assert Pricing.cached_rate("model-with-no-cache-rate", cache) == nil
      assert Pricing.cached_rate(nil, cache) == nil
    end
  end

  describe "record + summary" do
    setup do
      Config.add_project("acme", %{"markup" => 1.5})

      Config.put_model(%Config.Model{
        name: "acme/gpt",
        model: "gpt-4o",
        input_price: 2.5,
        output_price: 10.0
      })

      :ok
    end

    test "records usage and aggregates tokens per scope" do
      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000
      })

      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 200_000,
        "completion_tokens" => 100_000
      })

      s = Usage.summary("acme", :day)
      assert s.totals.in == 1_200_000
      assert s.totals.out == 600_000
      assert s.totals.total == 1_800_000
      assert s.totals.count == 2
    end

    test "cost uses the model's manual price; billable applies the project markup" do
      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000
      })

      s = Usage.summary("acme", :month)
      # 1M in × 2.5/1M + 0.5M out × 10/1M = 2.5 + 5.0 = 7.5
      assert_in_delta s.totals.cost, 7.5, 0.0001
      # × 1.5 markup
      assert_in_delta s.totals.billable, 11.25, 0.0001
    end

    test "near_budget? warns in the band between the alert threshold and the hard cap" do
      Config.put_model(%Config.Model{name: "acme/p", model: "gpt-4o", input_price: 1.0, output_price: 0.0})
      Config.add_project("bud", %{"budget" => 10.0})

      # 6.0 spent of a 10.0 budget = 60%: below the default 80% alert.
      Usage.record("bud/x", "acme/p", %{"prompt_tokens" => 6_000_000, "completion_tokens" => 0})
      refute Usage.near_budget?("bud")
      assert_in_delta Usage.budget_ratio("bud"), 0.6, 0.0001

      # +2.5 -> 8.5/10 = 85%: in the alert band.
      Usage.record("bud/x", "acme/p", %{"prompt_tokens" => 2_500_000, "completion_tokens" => 0})
      assert Usage.near_budget?("bud")

      # A configured threshold moves the band.
      Config.update_project("bud", %{"budget_alert_at" => 0.9})
      refute Usage.near_budget?("bud")

      # No budget set -> never near.
      refute Usage.near_budget?("no-such-project")
      assert Usage.budget_ratio("no-such-project") == nil
    end

    test "near_budget? is false once over the hard cap (the gate takes over)" do
      Config.put_model(%Config.Model{name: "over/p", model: "gpt-4o", input_price: 1.0, output_price: 0.0})
      Config.add_project("over", %{"budget" => 5.0})

      Usage.record("over/x", "over/p", %{"prompt_tokens" => 6_000_000, "completion_tokens" => 0})
      assert Usage.over_budget?("over")
      refute Usage.near_budget?("over")
    end

    test "an unpriced model falls back to the seed price book" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})
      Usage.record("assistant", "mini", %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})

      s = Usage.summary("default", :day)
      # gpt-4o-mini seed input price 0.15/1M
      assert_in_delta s.totals.cost, 0.15, 0.0001
    end

    test "cached input is recorded and priced at the model's cache rate, not full input" do
      Config.put_model(%Config.Model{
        name: "acme/cached",
        model: "gpt-4o",
        input_price: 2.5,
        output_price: 10.0,
        cached_input_price: 0.25
      })

      # 1M input, 800k served from cache, no output.
      Usage.record("acme/sales", "acme/cached", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 0,
        "cached_tokens" => 800_000
      })

      s = Usage.summary("acme", :month)
      # fresh 200k × 2.5 + cached 800k × 0.25 = 0.5 + 0.2 = 0.7 (would be 2.5 priced at full input)
      assert_in_delta s.totals.cost, 0.7, 0.0001
    end

    test "OpenAI's nested prompt_tokens_details.cached_tokens is counted too" do
      Config.put_model(%Config.Model{
        name: "acme/oai",
        model: "gpt-4o",
        input_price: 2.5,
        output_price: 0.0,
        cached_input_price: 0.0
      })

      Usage.record("acme/sales", "acme/oai", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 0,
        "prompt_tokens_details" => %{"cached_tokens" => 1_000_000}
      })

      s = Usage.summary("acme", :month)
      # all input cache-read at 0.0 -> free
      assert_in_delta s.totals.cost, 0.0, 0.0001
    end

    test "a total-only usage report is attributed to input" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})
      Usage.record("assistant", "mini", %{"total_tokens" => 400_000})

      s = Usage.summary("default", :day)
      assert s.totals.in == 400_000
      assert s.totals.out == 0
    end

    test "scopes are isolated; :all merges them and breaks down per project" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})

      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 0
      })

      Usage.record("assistant", "mini", %{"prompt_tokens" => 500_000, "completion_tokens" => 0})

      assert Usage.summary("acme", :day).totals.total == 1_000_000
      assert Usage.summary("default", :day).totals.total == 500_000

      all = Usage.summary(:all, :day)
      assert all.totals.total == 1_500_000
      assert Enum.map(all.by_project, & &1.key) |> Enum.sort() == ["acme", "default"]
    end

    test "zero/empty usage is not recorded" do
      Usage.record("acme/sales", "acme/gpt", %{"prompt_tokens" => 0, "completion_tokens" => 0})
      Usage.record("acme/sales", "acme/gpt", nil)

      assert Usage.summary("acme", :day).totals.count == 0
    end
  end

  describe "invoice" do
    setup do
      Config.add_project("acme", %{"markup" => 1.5})

      Config.put_model(%Config.Model{
        name: "acme/gpt",
        model: "gpt-4o",
        input_price: 2.5,
        output_price: 10.0
      })

      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000
      })

      month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
      {:ok, month: month}
    end

    test "builds a per-model invoice with cost, markup and billable", %{month: month} do
      inv = Usage.invoice("acme", month: month, tz: "Etc/UTC")

      assert inv.project == "acme"
      assert inv.markup == 1.5
      assert inv.period.label == month
      assert [%{key: "acme/gpt", total: 1_500_000}] = inv.line_items
      assert_in_delta inv.totals.cost, 7.5, 0.0001
      assert_in_delta inv.totals.billable, 11.25, 0.0001
    end

    test "renders CSV and Markdown", %{month: month} do
      inv = Usage.invoice("acme", month: month, tz: "Etc/UTC")

      csv = Pepe.Usage.Invoice.to_csv(inv)
      assert csv =~ "model,input_tokens,output_tokens,total_tokens,cost,billable"
      assert csv =~ "acme/gpt,1000000,500000,1500000,7.50,11.25"
      assert csv =~ "TOTAL,1000000,500000,1500000,7.50,11.25"

      md = Pepe.Usage.Invoice.to_markdown(inv)
      assert md =~ "# Invoice - acme"
      assert md =~ "markup **1.5**"
      assert md =~ "USD 11.25"
      assert Pepe.Usage.Invoice.basename(inv) == "acme-#{month}"
    end

    test "a different month is empty" do
      inv = Usage.invoice("acme", month: "1999-01", tz: "Etc/UTC")
      assert inv.line_items == []
      assert inv.totals.total == 0
    end

    test "the export_invoice tool saves a file and returns it" do
      assert {:ok, out} = Pepe.Tools.Invoice.run(%{"project" => "acme"}, %{})
      assert out =~ "Saved invoice to"
      assert out =~ "# Invoice - acme"

      assert {:error, msg} = Pepe.Tools.Invoice.run(%{"project" => "ghost"}, %{})
      assert msg =~ "unknown project"
    end
  end

  describe "project markup" do
    test "defaults to 1.0 and reads a configured multiplier" do
      assert Config.project_markup(nil) == 1.0
      assert Config.project_markup("nope") == 1.0

      Config.add_project("acme", %{"markup" => 1.3})
      assert Config.project_markup("acme") == 1.3
    end
  end
end
