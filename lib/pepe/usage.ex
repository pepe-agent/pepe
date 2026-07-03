defmodule Pepe.Usage do
  @moduledoc """
  Token metering for billing. Every model call the runtime makes is recorded to a durable
  per-project ledger (`Pepe.Usage.Log`); this module records those entries and aggregates
  them into time buckets - hour, day, week, month, year - with the money math on top.

  ## Three numbers, not two

  A conversation that runs on a ChatGPT Plus or Claude Max login costs nothing per token:
  the month was paid for in advance, whether you send one message or ten thousand. It is
  worth exactly the same to the client either way. So the ledger keeps the two apart.

    * **`list`** - `tokens × the model's price` (per 1M; see `Pepe.Pricing`). What these
      tokens would have cost on the API, whether or not they did.
    * **`billable`** - `list × the project's markup`. What the client pays, and it is
      deliberately computed from `list` rather than from what we spent. The subscription
      will run out one day and the same work will fall through to the paid API, and on that
      day the client's price must not move. A price that tracks our supply arrangements is a
      price we have to explain.
    * **`cost`** - what we actually paid *these tokens*. Zero on a subscription connection,
      because at the margin it is. The month's flat fee is counted once, as
      `subscriptions`, from each subscription connection's `monthly_cost`.

  Margin is therefore `billable - cost - subscriptions`, and the point of the split is that
  it comes out right. Charging the subscription's tokens to ourselves at API prices, which
  is what a single number forces you to do, understates the margin: it books forty dollars
  of cost in a month where twenty dollars left the bank.

  Whether a call ran on a subscription is decided **when it is recorded**, not when it is
  read. A connection can be switched from an API key to a login, or the other way, and last
  month's entries must not silently change meaning when it happens.
  """

  alias Pepe.Project
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Pricing
  alias Pepe.Usage.Log

  @granularities [:hour, :day, :week, :month, :year]

  @doc "The supported billing cycles, coarsest reads built from finest data."
  def granularities, do: @granularities

  @doc """
  Record one model call's token usage against the agent's project. `usage` is the provider's
  usage map (`\"prompt_tokens\"`, `\"completion_tokens\"`, `\"total_tokens\"`). No-ops when
  nothing meaningful was reported.

  Pass the `Pepe.Config.Model` rather than its name where you have it: the entry then
  remembers whether it ran on a subscription, which is the one fact that cannot be recovered
  later (the connection may since have been switched to an API key, or away from one).
  """
  @spec record(String.t(), Model.t() | String.t(), map() | nil) :: :ok
  def record(agent_handle, %Model{} = model, usage) when is_map(usage),
    do: append(agent_handle, model.name, usage, Model.subscription?(model))

  def record(agent_handle, model_name, usage) when is_map(usage),
    do: append(agent_handle, model_name, usage, false)

  def record(_agent, _model, _usage), do: :ok

  defp append(agent_handle, model_name, usage, subscription?) do
    in_tok = int(usage["prompt_tokens"])
    out_tok = int(usage["completion_tokens"])
    total = int(usage["total_tokens"])
    cached = cached_input(usage)

    # Some providers report only a total - attribute it to input rather than lose it.
    {in_tok, out_tok} =
      cond do
        in_tok > 0 or out_tok > 0 -> {in_tok, out_tok}
        total > 0 -> {total, 0}
        true -> {0, 0}
      end

    if in_tok + out_tok > 0 do
      entry = %{
        "at" => System.system_time(:second),
        "agent" => to_string(agent_handle),
        "model" => to_string(model_name),
        "in" => in_tok,
        "out" => out_tok
      }

      # Only written when true/non-zero, so the ledger's shape does not change for anybody whose
      # provider reports no cache hits (or an older Pepe), and those entries read exactly as before.
      entry = if subscription?, do: Map.put(entry, "sub", true), else: entry
      entry = if cached > 0, do: Map.put(entry, "cached", min(cached, in_tok)), else: entry

      Log.append(Project.of(to_string(agent_handle)), entry)
    end

    :ok
  end

  # Cache-read input tokens the provider reported, across the shapes they use: a normalized top-level
  # `cached_tokens` (the Anthropic/Responses adapters set this), or OpenAI's nested
  # `prompt_tokens_details.cached_tokens`. A subset of `prompt_tokens`.
  defp cached_input(usage) do
    top = int(usage["cached_tokens"])
    if top > 0, do: top, else: int(get_in(usage, ["prompt_tokens_details", "cached_tokens"]))
  end

  @currency_symbols %{"USD" => "$", "BRL" => "R$", "EUR" => "€", "GBP" => "£"}

  @doc "Format `amount` in the configured billing currency, e.g. `$13.55` or `R$ 226.80`."
  def format_cost(amount) when is_number(amount) do
    currency = Config.currency()
    n = :erlang.float_to_binary(amount / 1, decimals: 2)

    case @currency_symbols[currency] do
      nil -> "#{currency} #{n}"
      "$" -> "$#{n}"
      sym -> "#{sym} #{n}"
    end
  end

  @doc """
  Billable spend (in the billing currency) for `project` in the current month, since
  the later of: the month's start, or its last `reset_budget/1` call (if any fell
  within it). This is what the pre-flight budget gate and the dashboard badge use -
  `Pepe.Usage.Invoice`/`summary/3` read the ledger directly and are never affected
  by a reset, so the real accounting record stays intact.
  """
  @spec month_to_date(String.t() | nil) :: float()
  def month_to_date(project) do
    tz = Config.default_timezone()
    key = bucket_key(System.os_time(:second), :month, tz)
    reset_at = Config.project_budget_reset_at(project)
    cache = Pricing.load_cache()
    models = Map.new(Config.models(), &{&1.name, &1})

    # Strictly-after (not >=): entries only have second resolution, and
    # reset_budget/1 can't record its own position in the ledger (it's stored on
    # the project, not appended as a marker) - a usage record and a reset landing
    # in the same wall-clock second must resolve as "recorded before the reset",
    # never the reverse, or the reset would look like it silently did nothing.
    entries =
      project
      |> Log.entries()
      |> Enum.filter(fn e ->
        bucket_key(e["at"], :month, tz) == key and (is_nil(reset_at) or e["at"] > reset_at)
      end)

    prices = price_lookup(entries, models, cache)
    markups = markup_lookup(entries)
    Enum.reduce(entries, 0.0, fn e, acc -> acc + price(e, prices, markups)["billable"] end)
  end

  @doc """
  Is `project` at or over its monthly spend cap? Always `false` when no cap is set
  (see `Pepe.Config.project_budget/1`). This is the runtime's pre-flight budget gate.
  """
  @spec over_budget?(String.t() | nil) :: boolean()
  def over_budget?(project) do
    case Config.project_budget(project) do
      nil -> false
      budget -> month_to_date(project) >= budget
    end
  end

  @doc "Fraction of `project`'s monthly budget spent so far (spend / budget), or `nil` if no budget is set."
  @spec budget_ratio(String.t() | nil) :: float() | nil
  def budget_ratio(project) do
    case Config.project_budget(project) do
      nil -> nil
      budget when budget > 0 -> month_to_date(project) / budget
      _ -> nil
    end
  end

  @doc """
  Is `project` at/over its soft alert threshold (default 80%, `Config.project_budget_alert_at/1`)
  but not yet over the hard cap? This is the "warn before the gate slams" band - `false` with no
  budget set, and `false` once `over_budget?/1` is true (the gate takes over there).
  """
  @spec near_budget?(String.t() | nil) :: boolean()
  def near_budget?(project) do
    case budget_ratio(project) do
      nil -> false
      ratio -> ratio >= Config.project_budget_alert_at(project) and ratio < 1.0
    end
  end

  @doc "Reset `project`'s budget counter early, before the natural month boundary."
  @spec reset_budget(String.t() | nil) :: :ok | {:error, :not_found}
  def reset_budget(project), do: Config.reset_project_budget(project)

  @doc "Unix timestamp of `project`'s last budget reset, or `nil` if it's never been reset."
  @spec budget_reset_at(String.t() | nil) :: integer() | nil
  def budget_reset_at(project), do: Config.project_budget_reset_at(project)

  @doc "Unix timestamp of `project`'s last message-count reset this month, or `nil`."
  @spec messages_reset_at(String.t() | nil) :: integer() | nil
  def messages_reset_at(project), do: Pepe.Usage.Messages.last_reset_at(project)

  @doc "Record one customer-originated message against `project`'s monthly counter."
  @spec record_message(String.t() | nil) :: :ok
  def record_message(project), do: Pepe.Usage.Messages.record(project)

  @doc "How many customer messages `project` has been recorded for this month."
  @spec message_count_month_to_date(String.t() | nil) :: non_neg_integer()
  def message_count_month_to_date(project), do: Pepe.Usage.Messages.month_to_date(project)

  @doc "Reset `project`'s message counter early, before the natural month boundary."
  @spec reset_messages(String.t() | nil) :: :ok
  def reset_messages(project), do: Pepe.Usage.Messages.reset(project)

  @doc """
  Is `project` at or over its monthly customer-message cap? Always `false` when no
  cap is set (see `Pepe.Config.project_message_limit/1`). Independent of
  `over_budget?/1` - a project can have either, both, or neither cap.
  """
  @spec over_message_limit?(String.t() | nil) :: boolean()
  def over_message_limit?(project) do
    case Config.project_message_limit(project) do
      nil -> false
      limit -> message_count_month_to_date(project) >= limit
    end
  end

  @doc """
  Aggregate a scope's usage into buckets at `granularity`.

  `scope` is `nil`/`\"root\"` (root only), a project name, or `:all`/`\"all\"`.
  Options: `:tz` (billing-day timezone, default the configured one), `:limit`
  (most-recent buckets to return, default 60).

  Returns a map with `:buckets` (each `%{key, in, out, total, list, cost, billable}`,
  oldest->newest), `:totals`, and `:by_model` / `:by_agent` / `:by_project` breakdowns, plus
  the `:currency` label, the month's `:subscriptions` (the flat fees behind any subscription
  connection that was actually used) and the `:margin` those make honest.
  """
  def summary(scope, granularity, opts \\ []) when granularity in @granularities do
    tz = opts[:tz] || Config.default_timezone()
    limit = opts[:limit] || 60

    # Load the live price cache and every model's manual price once, up front, and
    # resolve price/markup per distinct model/project (not per row - see
    # price_lookup/3), so pricing thousands of ledger entries never touches disk or
    # rescans the price book per row.
    cache = Pricing.load_cache()
    models = Map.new(Config.models(), &{&1.name, &1})
    entries = load_entries(scope)
    prices = price_lookup(entries, models, cache)
    markups = markup_lookup(entries)
    priced = Enum.map(entries, &price(&1, prices, markups))

    buckets =
      priced
      |> Enum.group_by(&bucket_key(&1["at"], granularity, tz))
      |> Enum.map(fn {key, es} -> Map.put(sum(es), :key, key) end)
      |> Enum.sort_by(& &1.key)
      |> Enum.take(-limit)

    totals = sum(priced)
    subs = subscriptions(priced, models)

    %{
      granularity: granularity,
      currency: Config.currency(),
      buckets: buckets,
      totals: totals,
      subscriptions: subs,
      margin: totals.billable - totals.cost - subs,
      by_model: group_sum(priced, "model"),
      by_agent: group_sum(priced, "agent"),
      by_project: by_project(priced)
    }
  end

  # The flat monthly fee behind every subscription connection that actually served a call in
  # this period, counted once each however many calls it served. Charged in full and not
  # pro-rated: a month of Claude Max costs a month of Claude Max whether it was used on the
  # first day or the last.
  #
  # A connection whose `monthly_cost` we were never told contributes zero, which makes the
  # reported margin an optimistic bound rather than a lie - and `pepe doctor` is where that
  # gets pointed out.
  defp subscriptions(priced, models) do
    priced
    |> Enum.filter(& &1["sub"])
    |> Enum.map(& &1["model"])
    |> Enum.uniq()
    |> Enum.map(fn name ->
      case models[name] do
        %Model{monthly_cost: fee} when is_number(fee) -> fee / 1
        _ -> 0.0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  Build a billing invoice for one project over a calendar month.

  `opts`: `:month` (`\"YYYY-MM\"`, default the current month in the billing tz),
  `:tz`. Returns a map with the `:period`, per-model `:line_items`, `:totals`, the
  `:markup` and `:currency` - ready to render (`Pepe.Usage.Invoice`).
  """
  def invoice(project, opts \\ []) do
    tz = opts[:tz] || Config.default_timezone()
    {from, to, label} = month_range(opts[:month], tz)

    cache = Pricing.load_cache()
    models = Map.new(Config.models(), &{&1.name, &1})

    raw_entries =
      project
      |> Log.entries()
      |> Enum.filter(fn e -> is_integer(e["at"]) and e["at"] >= from and e["at"] < to end)

    prices = price_lookup(raw_entries, models, cache)
    markups = markup_lookup(raw_entries)
    entries = Enum.map(raw_entries, &price(&1, prices, markups))

    line_items =
      entries
      |> Enum.group_by(& &1["model"])
      |> Enum.map(fn {model, es} -> Map.put(sum(es), :key, model) end)
      |> Enum.sort_by(& &1.billable, :desc)

    %{
      project: project,
      currency: Config.currency(),
      markup: Config.project_markup(project),
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

  # {model name => {input_price, output_price}} for just the distinct models present
  # in `entries`, resolved once - a ledger has thousands of rows but usually a
  # handful of distinct models, and price_for/3's cache-miss fallback does an O(cache
  # size) scan, so re-resolving per row (not per distinct model) made pricing a
  # month of usage scale with row count × price-book size instead of just row count.
  defp price_lookup(entries, models, cache) do
    entries |> Enum.map(& &1["model"]) |> Enum.uniq() |> Map.new(&{&1, price_for(&1, models, cache)})
  end

  # {project => markup} for just the distinct projects present in `entries`, same
  # reasoning as price_lookup/3 (a handful of distinct projects, not one lookup
  # per row).
  defp markup_lookup(entries) do
    entries |> Enum.map(& &1["project"]) |> Enum.uniq() |> Map.new(&{&1, Config.project_markup(nil_scope(&1))})
  end

  # Decorate an entry with cost (provider) and billable (cost × project markup),
  # from the lookup tables built by price_lookup/3 and markup_lookup/1.
  defp price(e, prices, markups) do
    {ip, op, cp} = Map.fetch!(prices, e["model"])
    list = Pricing.cost(e["in"], e["out"], e["cached"] || 0, ip, op, cp)
    markup = Map.fetch!(markups, e["project"])

    e
    |> Map.put("list", list)
    # What the client pays, always from the list price. A subscription is our supply
    # arrangement, not theirs: when it runs out and the work falls through to the paid API,
    # their invoice must read the same as it did the month before.
    |> Map.put("billable", list * markup)
    # What we actually paid for these tokens. Nothing, on a subscription: the month was
    # bought in advance and is counted once, as `subscriptions`.
    |> Map.put("cost", if(e["sub"], do: 0.0, else: list))
  end

  @doc """
  The `{input_price, output_price, cached_input_price}` per 1M tokens for a model connection: its
  own manual prices if set, else the layered price book (live cache -> seed) for its upstream id.
  The cache-read price comes from the model's manual `cached_input_price` or the price book; `nil`
  means "price cached input as normal input" (no worse than before). `models` is a name->Model map
  and `cache` the loaded price cache, so this stays disk-free when pricing many rows.
  """
  @spec price_for(String.t(), map(), map()) :: {number() | nil, number() | nil, number() | nil}
  def price_for(model_name, models \\ %{}, cache \\ %{}) do
    case Map.get(models, model_name) || Config.get_model(model_name) do
      %{input_price: ip, output_price: op, cached_input_price: cp} when is_number(ip) or is_number(op) ->
        {ip, op, cp}

      %{model: upstream} ->
        {i, o} = Pricing.lookup(upstream, cache) || {nil, nil}
        {i, o, Pricing.cached_rate(upstream, cache)}

      _ ->
        {i, o} = Pricing.lookup(model_name, cache) || {nil, nil}
        {i, o, Pricing.cached_rate(model_name, cache)}
    end
  end

  defp sum(entries) do
    Enum.reduce(
      entries,
      %{in: 0, out: 0, total: 0, list: 0.0, cost: 0.0, billable: 0.0, count: 0},
      fn e, a ->
        %{
          in: a.in + e["in"],
          out: a.out + e["out"],
          total: a.total + e["in"] + e["out"],
          list: a.list + e["list"],
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

  defp by_project(entries) do
    entries
    |> Enum.group_by(& &1["project"])
    |> Enum.map(fn {c, es} ->
      sum(es) |> Map.merge(%{key: c, markup: Config.project_markup(nil_scope(c))})
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
