defmodule Pepe.Usage do
  @moduledoc """
  Token metering for billing. Every model call the runtime makes is recorded to a
  durable per-company ledger (`Pepe.Usage.Log`); this module records those
  entries and aggregates them into time buckets - hour, day, week, month, year -
  with the money math on top.

  Cost is `tokens × the model's price` (per 1M tokens; see `Pepe.Pricing`). The
  amount to bill a client is `cost × the company's markup` - a company with no
  markup bills exactly the provider cost. Both figures are kept side by side so the
  operator always sees the real cost, never just the marked-up number.
  """

  alias Pepe.Company
  alias Pepe.Config
  alias Pepe.Pricing
  alias Pepe.Usage.Log

  @granularities [:hour, :day, :week, :month, :year]

  @doc "The supported billing cycles, coarsest reads built from finest data."
  def granularities, do: @granularities

  @doc """
  Record one model call's token usage against the agent's company. `usage` is the
  provider's usage map (`\"prompt_tokens\"`, `\"completion_tokens\"`,
  `\"total_tokens\"`). No-ops when nothing meaningful was reported.
  """
  @spec record(String.t(), String.t(), map() | nil) :: :ok
  def record(agent_handle, model_name, usage) when is_map(usage) do
    in_tok = int(usage["prompt_tokens"])
    out_tok = int(usage["completion_tokens"])
    total = int(usage["total_tokens"])

    # Some providers report only a total - attribute it to input rather than lose it.
    {in_tok, out_tok} =
      cond do
        in_tok > 0 or out_tok > 0 -> {in_tok, out_tok}
        total > 0 -> {total, 0}
        true -> {0, 0}
      end

    if in_tok + out_tok > 0 do
      Log.append(Company.of(to_string(agent_handle)), %{
        "at" => System.system_time(:second),
        "agent" => to_string(agent_handle),
        "model" => to_string(model_name),
        "in" => in_tok,
        "out" => out_tok
      })
    end

    :ok
  end

  def record(_agent, _model, _usage), do: :ok

  @doc """
  Aggregate a scope's usage into buckets at `granularity`.

  `scope` is `nil`/`\"root\"` (root only), a company name, or `:all`/`\"all\"`.
  Options: `:tz` (billing-day timezone, default the configured one), `:limit`
  (most-recent buckets to return, default 60).

  Returns a map with `:buckets` (each `%{key, in, out, total, cost, billable}`,
  oldest->newest), `:totals`, and `:by_model` / `:by_agent` / `:by_company`
  breakdowns, plus the `:currency` label.
  """
  def summary(scope, granularity, opts \\ []) when granularity in @granularities do
    tz = opts[:tz] || Config.default_timezone()
    limit = opts[:limit] || 60

    # Load the live price cache and every model's manual price once, up front, so
    # pricing thousands of ledger entries never touches disk per row.
    cache = Pricing.load_cache()
    models = Map.new(Config.models(), &{&1.name, &1})
    priced = scope |> load_entries() |> Enum.map(&price(&1, models, cache))

    buckets =
      priced
      |> Enum.group_by(&bucket_key(&1["at"], granularity, tz))
      |> Enum.map(fn {key, es} -> Map.put(sum(es), :key, key) end)
      |> Enum.sort_by(& &1.key)
      |> Enum.take(-limit)

    %{
      granularity: granularity,
      currency: Config.currency(),
      buckets: buckets,
      totals: sum(priced),
      by_model: group_sum(priced, "model"),
      by_agent: group_sum(priced, "agent"),
      by_company: by_company(priced)
    }
  end

  @doc """
  Build a billing invoice for one company over a calendar month.

  `opts`: `:month` (`\"YYYY-MM\"`, default the current month in the billing tz),
  `:tz`. Returns a map with the `:period`, per-model `:line_items`, `:totals`, the
  `:markup` and `:currency` - ready to render (`Pepe.Usage.Invoice`).
  """
  def invoice(company, opts \\ []) do
    tz = opts[:tz] || Config.default_timezone()
    {from, to, label} = month_range(opts[:month], tz)

    cache = Pricing.load_cache()
    models = Map.new(Config.models(), &{&1.name, &1})

    entries =
      company
      |> Log.entries()
      |> Enum.filter(fn e -> is_integer(e["at"]) and e["at"] >= from and e["at"] < to end)
      |> Enum.map(&price(&1, models, cache))

    line_items =
      entries
      |> Enum.group_by(& &1["model"])
      |> Enum.map(fn {model, es} -> Map.put(sum(es), :key, model) end)
      |> Enum.sort_by(& &1.billable, :desc)

    %{
      company: company,
      currency: Config.currency(),
      markup: Config.company_markup(company),
      period: %{label: label, from: from, to: to},
      line_items: line_items,
      totals: sum(entries),
      generated_at: System.system_time(:second)
    }
  end

  # {from_unix, to_unix, "YYYY-MM"} for a month string (default the current month).
  defp month_range(month, tz) do
    {y, m} = parse_month(month, tz)
    {ny, nm} = if m == 12, do: {y + 1, 1}, else: {y, m + 1}
    {start_of_month(y, m, tz), start_of_month(ny, nm, tz), pad([y, m], "~4..0B-~2..0B")}
  end

  defp parse_month(month, tz) do
    with str when is_binary(str) <- month,
         [ys, ms] <- String.split(str, "-", parts: 2),
         {y, _} <- Integer.parse(ys),
         {m, _} when m in 1..12 <- Integer.parse(ms) do
      {y, m}
    else
      _ ->
        now =
          case DateTime.now(tz) do
            {:ok, dt} -> dt
            _ -> DateTime.utc_now()
          end

        {now.year, now.month}
    end
  end

  defp start_of_month(y, m, tz) do
    date = Date.new!(y, m, 1)

    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.to_unix(dt)
      {:ambiguous, dt, _} -> DateTime.to_unix(dt)
      {:gap, _, dt} -> DateTime.to_unix(dt)
      _ -> date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    end
  end

  ## internals

  defp load_entries(scope) when scope in [:all, "all"], do: Log.entries_for(:all)
  defp load_entries(scope), do: Log.entries(scope)

  # Decorate an entry with cost (provider) and billable (cost × company markup).
  defp price(e, models, cache) do
    {ip, op} = price_for(e["model"], models, cache)
    cost = Pricing.cost(e["in"], e["out"], ip, op)
    markup = Config.company_markup(nil_scope(e["company"]))

    e
    |> Map.put("cost", cost)
    |> Map.put("billable", cost * markup)
  end

  @doc """
  The `{input_price, output_price}` per 1M tokens for a model connection: its own
  manual prices if set, else the layered price book (live cache -> seed) for its
  upstream id. `models` is a name->Model map and `cache` the loaded price cache, so
  this stays disk-free when pricing many rows.
  """
  @spec price_for(String.t(), map(), map()) :: {number() | nil, number() | nil}
  def price_for(model_name, models \\ %{}, cache \\ %{}) do
    case Map.get(models, model_name) || Config.get_model(model_name) do
      %{input_price: ip, output_price: op} when is_number(ip) or is_number(op) ->
        {ip, op}

      %{model: upstream} ->
        Pricing.lookup(upstream, cache) || {nil, nil}

      _ ->
        Pricing.lookup(model_name, cache) || {nil, nil}
    end
  end

  defp sum(entries) do
    Enum.reduce(
      entries,
      %{in: 0, out: 0, total: 0, cost: 0.0, billable: 0.0, count: 0},
      fn e, a ->
        %{
          in: a.in + e["in"],
          out: a.out + e["out"],
          total: a.total + e["in"] + e["out"],
          cost: a.cost + e["cost"],
          billable: a.billable + e["billable"],
          count: a.count + 1
        }
      end
    )
  end

  defp group_sum(entries, field) do
    entries
    |> Enum.group_by(& &1[field])
    |> Enum.map(fn {k, es} -> Map.put(sum(es), :key, k) end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp by_company(entries) do
    entries
    |> Enum.group_by(& &1["company"])
    |> Enum.map(fn {c, es} ->
      sum(es) |> Map.merge(%{key: c, markup: Config.company_markup(nil_scope(c))})
    end)
    |> Enum.sort_by(& &1.billable, :desc)
  end

  defp nil_scope("root"), do: nil
  defp nil_scope(s), do: s

  # Bucket a unix timestamp into a sortable string key, in the billing timezone.
  defp bucket_key(at, granularity, tz) do
    dt = local_dt(at, tz)

    case granularity do
      :hour -> pad([dt.year, dt.month, dt.day, dt.hour], "~4..0B-~2..0B-~2..0B ~2..0B:00")
      :day -> pad([dt.year, dt.month, dt.day], "~4..0B-~2..0B-~2..0B")
      :week -> week_key(dt)
      :month -> pad([dt.year, dt.month], "~4..0B-~2..0B")
      :year -> Integer.to_string(dt.year)
    end
  end

  defp local_dt(at, tz) do
    with {:ok, utc} <- DateTime.from_unix(at),
         {:ok, local} <- DateTime.shift_zone(utc, tz) do
      local
    else
      _ -> DateTime.from_unix!(at || 0)
    end
  end

  defp week_key(dt) do
    d = Date.beginning_of_week(DateTime.to_date(dt))
    pad([d.year, d.month, d.day], "~4..0B-~2..0B-~2..0B")
  end

  defp pad(args, fmt), do: :io_lib.format(fmt, args) |> to_string()

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(_), do: 0
end
