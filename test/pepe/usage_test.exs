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
  end

  describe "record + summary" do
    setup do
      Config.add_company("acme", %{"markup" => 1.5})

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

    test "cost uses the model's manual price; billable applies the company markup" do
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

    test "an unpriced model falls back to the seed price book" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})
      Usage.record("assistant", "mini", %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})

      s = Usage.summary("root", :day)
      # gpt-4o-mini seed input price 0.15/1M
      assert_in_delta s.totals.cost, 0.15, 0.0001
    end

    test "a total-only usage report is attributed to input" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})
      Usage.record("assistant", "mini", %{"total_tokens" => 400_000})

      s = Usage.summary("root", :day)
      assert s.totals.in == 400_000
      assert s.totals.out == 0
    end

    test "scopes are isolated; :all merges them and breaks down per company" do
      Config.put_model(%Config.Model{name: "mini", model: "gpt-4o-mini"})

      Usage.record("acme/sales", "acme/gpt", %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 0
      })

      Usage.record("assistant", "mini", %{"prompt_tokens" => 500_000, "completion_tokens" => 0})

      assert Usage.summary("acme", :day).totals.total == 1_000_000
      assert Usage.summary("root", :day).totals.total == 500_000

      all = Usage.summary(:all, :day)
      assert all.totals.total == 1_500_000
      assert Enum.map(all.by_company, & &1.key) |> Enum.sort() == ["acme", "root"]
    end

    test "zero/empty usage is not recorded" do
      Usage.record("acme/sales", "acme/gpt", %{"prompt_tokens" => 0, "completion_tokens" => 0})
      Usage.record("acme/sales", "acme/gpt", nil)

      assert Usage.summary("acme", :day).totals.count == 0
    end
  end

  describe "invoice" do
    setup do
      Config.add_company("acme", %{"markup" => 1.5})

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

      assert inv.company == "acme"
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
      assert md =~ "# Invoice — acme"
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
      assert {:ok, out} = Pepe.Tools.Invoice.run(%{"company" => "acme"}, %{})
      assert out =~ "Saved invoice to"
      assert out =~ "# Invoice — acme"

      assert {:error, msg} = Pepe.Tools.Invoice.run(%{"company" => "ghost"}, %{})
      assert msg =~ "unknown company"
    end
  end

  describe "company markup" do
    test "defaults to 1.0 and reads a configured multiplier" do
      assert Config.company_markup(nil) == 1.0
      assert Config.company_markup("nope") == 1.0

      Config.add_company("acme", %{"markup" => 1.3})
      assert Config.company_markup("acme") == 1.3
    end
  end
end
