defmodule PepeWeb.UsageController do
  @moduledoc """
  The read side of the `/v1` API: what has been spent, by whom, on what.

      GET /v1/usage             # aggregated into time buckets
      GET /v1/usage/events      # one row per model call
      GET /v1/usage/runs        # one row per inbound message
      GET /v1/usage/runs/:id    # one message, call by call

  Four zoom levels on the same ledger. `/usage` is the invoice-shaped view; `/events` is the
  raw ledger; `/runs` is the one an operator actually asks for, because a single message can
  cost several model calls (the agent answers, calls a tool, is fed the result, calls
  another) and only the run groups them back into the message that caused them.

  Authority comes entirely from the token, resolved once by `PepeWeb.UsageAuth`: which
  projects it may read, whether it is pinned to one agent, how much of the money it may see
  and whether it may see conversation content. Request parameters can only *narrow* that;
  a client asking for another project, another agent or a wider price view than its token
  carries does not get one.

  Every money figure follows `Pepe.Usage.View`: `billable` is what the client pays,
  `list` is the same tokens without the markup, and `cost`/`margin` are operator-only.
  """
  use PepeWeb, :controller

  alias Pepe.Config
  alias Pepe.Trace
  alias Pepe.Usage
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs
  alias Pepe.Usage.View

  # A page ceiling the caller cannot raise: these reads price every row they return, and a
  # client asking for a million of them is a request to spend the server's memory.
  @max_limit 1_000
  @default_limit 100

  # Whitelisted, never String.to_atom on a query parameter.
  @granularities %{"hour" => :hour, "day" => :day, "week" => :week, "month" => :month, "year" => :year}

  ###
  ### GET /v1/usage
  ###

  def summary(conn, params) do
    ctx = conn.assigns.usage_ctx

    with {:ok, scope, filters} <- narrow(ctx, params),
         {:ok, granularity} <- granularity(params) do
      filters = default_window(filters)
      s = Usage.summary(scope, granularity, filters ++ [limit: bucket_limit(params, filters)])

      %{
        "object" => "usage.summary",
        "granularity" => to_string(granularity),
        "currency" => s.currency,
        "scope" => scope_object(scope, filters),
        "period" => %{"from" => filters[:from], "to" => filters[:to]},
        "totals" => View.amounts(s.totals, ctx.view),
        "buckets" => Enum.map(s.buckets, &keyed(&1, ctx.view)),
        "by_model" => Enum.map(s.by_model, &keyed(&1, ctx.view)),
        "by_agent" => Enum.map(s.by_agent, &keyed(&1, ctx.view)),
        "by_project" => Enum.map(s.by_project, &project_bucket(&1, ctx.view))
      }
      |> maybe_put_operator_totals(s, ctx.view)
      |> then(&json(conn, &1))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Unlike the paged reads, an aggregate has to see every entry in its window in order to sum
  # it - so a request with no window at all would load and price the scope's entire history,
  # once per request, for any caller holding a usage token. It gets a default window instead,
  # reported back as `period` so the report never quietly covers less than the caller thinks.
  # Asking for more is always allowed: pass `from`.
  @default_window_days 90

  defp default_window(filters) do
    if Keyword.has_key?(filters, :from),
      do: filters,
      else: Keyword.put(filters, :from, System.system_time(:second) - @default_window_days * 86_400)
  end

  # The month's flat subscription fees, and the margin they make honest, are the operator's own
  # supply arrangements - never part of a client's report. See `Pepe.Usage.View`.
  defp maybe_put_operator_totals(body, summary, view) do
    if View.operator?(view),
      do: Map.merge(body, %{"subscriptions" => View.round6(summary.subscriptions), "margin" => View.round6(summary.margin)}),
      else: body
  end

  defp keyed(bucket, view) do
    Map.merge(%{"key" => bucket.key}, View.amounts(bucket, view))
  end

  defp project_bucket(bucket, view) do
    base = keyed(bucket, view)
    if View.operator?(view), do: Map.put(base, "markup", bucket.markup), else: base
  end

  ###
  ### GET /v1/usage/events
  ###

  def events(conn, params) do
    ctx = conn.assigns.usage_ctx

    case narrow(ctx, params) do
      {:error, reason} ->
        error(conn, reason)

      {:ok, scope, filters} ->
        limit = limit(params)
        # One more than asked for, so "is there another page" is answered by the read itself
        # rather than by a second count query over the same window.
        opts = filters ++ [limit: limit + 1, cursor: integer(params["cursor"])]
        {page, more?} = scope |> Log.recent(opts) |> paginate(limit)

        json(conn, %{
          "object" => "list",
          "data" => page |> Usage.price_entries() |> Enum.map(&event_object(&1, ctx.view)),
          "has_more" => more?,
          "next_cursor" => next_cursor(page, more?)
        })
    end
  end

  defp event_object(entry, view) do
    %{
      "at" => entry["at"],
      "project" => entry["project"],
      "agent" => entry["agent"],
      "model" => entry["model"],
      "run_id" => entry["run_id"],
      "session" => entry["session"],
      "source" => entry["source"],
      "input_tokens" => entry["in"],
      "output_tokens" => entry["out"],
      "cached_input_tokens" => entry["cached"] || 0,
      "total_tokens" => entry["in"] + entry["out"],
      "subscription" => entry["sub"] == true
    }
    |> Map.merge(View.entry_money(entry, view))
  end

  ###
  ### GET /v1/usage/runs
  ###

  def runs(conn, params) do
    ctx = conn.assigns.usage_ctx

    with {:ok, scope, filters} <- narrow(ctx, params),
         :ok <- reject_unsupported(filters) do
      limit = limit(params)
      opts = filters ++ [limit: limit + 1, cursor: present(params["cursor"])]
      {page, more?} = scope |> Runs.list(opts) |> paginate(limit)
      totals = run_totals(scope, page)

      json(conn, %{
        "object" => "list",
        "data" => Enum.map(page, &run_object(&1, Map.get(totals, &1["id"]), ctx.view)),
        "has_more" => more?,
        "next_cursor" => next_cursor(page, more?)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # A run is not a model call: it has no single model, and asking for one `run_id` is the
  # detail endpoint, not a filter. Both are refused rather than ignored, because a filter
  # that silently does nothing returns a report the caller believes is narrower than it is,
  # and nothing about the response says otherwise.
  defp reject_unsupported(filters) do
    cond do
      Keyword.has_key?(filters, :model) -> {:error, :model_not_a_run_filter}
      Keyword.has_key?(filters, :run_id) -> {:error, :run_id_not_a_run_filter}
      true -> :ok
    end
  end

  # {run id => its summed money}, for a whole page of runs in one ledger read. A run with no
  # entry (its calls predate `run_id`, or it failed before any model answered) maps to nil and
  # reports zeroes rather than being dropped: it still happened, and it still took time.
  defp run_totals(scope, runs) do
    scope
    |> Log.entries_for_runs(Enum.map(runs, & &1["id"]))
    |> Usage.price_entries()
    |> Enum.group_by(& &1["run_id"])
    |> Map.new(fn {run_id, entries} -> {run_id, sum(entries)} end)
  end

  defp run_object(run, totals, view) do
    %{
      "id" => run["id"],
      "at" => run["at"],
      "project" => run["project"],
      "agent" => run["agent"],
      "session" => run["session"],
      "source" => run["source"],
      "ms" => run["ms"],
      "outcome" => run["outcome"],
      "tools" => run["tools"],
      "tool_calls" => run["tool_calls"]
    }
    |> Map.merge(View.amounts(totals || zero(), view))
  end

  ###
  ### GET /v1/usage/runs/:id
  ###

  def run(conn, %{"id" => id} = params) do
    ctx = conn.assigns.usage_ctx

    case narrow(ctx, params) do
      {:error, reason} ->
        error(conn, reason)

      {:ok, scope, filters} ->
        run = Runs.get(scope, id)

        if run && visible?(run, filters[:agent]),
          do: json(conn, run_detail(scope, run, ctx)),
          else: error(conn, :not_found)
    end
  end

  # An agent-locked token may only open a run its own agent made, even inside a project it
  # would otherwise be allowed to read. `Runs.get/2` scopes by project alone, so the agent
  # pin is applied here.
  defp visible?(_run, nil), do: true
  defp visible?(run, agent), do: run["agent"] == agent

  defp run_detail(scope, run, ctx) do
    entries = scope |> Log.entries_for_run(run["id"]) |> Usage.price_entries()

    run
    |> run_object(sum(entries), ctx.view)
    |> Map.put("object", "usage.run")
    |> Map.put("currency", Config.currency())
    # `calls` is already the count, from the shared amounts shape - the per-call rows go under
    # their own key rather than overloading it with a second meaning.
    |> Map.put("breakdown", Enum.map(entries, &call_object(&1, ctx.view)))
    |> maybe_put_content(scope, run, ctx)
  end

  # The per-call breakdown is the answer to "why did this message cost that much": each
  # iteration re-sends a context that the previous tool result just made bigger, so the cost
  # of a run is mostly its number of calls, not its number of tools.
  defp call_object(entry, view) do
    %{
      "at" => entry["at"],
      "model" => entry["model"],
      "input_tokens" => entry["in"],
      "output_tokens" => entry["out"],
      "cached_input_tokens" => entry["cached"] || 0,
      "total_tokens" => entry["in"] + entry["out"],
      "subscription" => entry["sub"] == true
    }
    |> Map.merge(View.entry_money(entry, view))
  end

  # Conversation content is a separate permission from money, and lives in `Pepe.Trace`, which
  # is trimmed per scope - so a run old enough to have lost its trace reports `null` content
  # rather than pretending it never had any. A token without the permission gets no key at all.
  defp maybe_put_content(detail, _scope, _run, %{content?: false}), do: detail

  defp maybe_put_content(detail, _scope, run, _ctx) do
    Map.put(detail, "content", trace_content(run))
  end

  # `Pepe.Trace.get/2` is keyed by a single scope, and the run itself already carries the
  # project it was recorded under - which is the one to ask for even when the token may read
  # several.
  defp trace_content(%{"id" => id, "project" => project}) do
    case Trace.get(project, id) do
      nil -> nil
      trace -> %{"prompt" => trace["prompt"], "events" => trace["events"]}
    end
  end

  ###
  ### scope + parameters
  ###

  # The token's authority intersected with what the request asked for. Only ever narrows:
  # `agent` is forced when the token is pinned to one, and a `project` outside the token's
  # reach is refused rather than quietly ignored - a silently wrong report is worse than an
  # error, because nobody notices it.
  defp narrow(ctx, params) do
    case requested_scope(ctx, params) do
      {:error, reason} ->
        {:error, reason}

      {:ok, scope} ->
        filters =
          [
            agent: ctx.agent || present(params["agent"]),
            model: present(params["model"]),
            source: present(params["source"]),
            session: present(params["session"]),
            run_id: present(params["run_id"]),
            from: integer(params["from"]),
            to: integer(params["to"])
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        {:ok, scope, filters}
    end
  end

  defp requested_scope(%{projects: :all}, params) do
    case present(params["project"]) do
      nil -> {:ok, :all}
      project -> {:ok, [Config.resolve_scope(project)]}
    end
  end

  defp requested_scope(%{projects: allowed}, params) do
    case present(params["project"]) do
      nil ->
        {:ok, allowed}

      project ->
        resolved = Config.resolve_scope(project)
        if resolved in allowed, do: {:ok, [resolved]}, else: {:error, :project_out_of_scope}
    end
  end

  defp granularity(params) do
    case params["granularity"] do
      nil -> {:ok, :day}
      value -> Map.fetch(@granularities, value) |> ok_or(:unknown_granularity)
    end
  end

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, value}, _reason), do: {:ok, value}

  defp scope_object(:all, filters), do: %{"projects" => "all", "agent" => filters[:agent]}
  defp scope_object(projects, filters), do: %{"projects" => projects, "agent" => filters[:agent]}

  defp limit(params), do: params["limit"] |> integer() |> clamp(1, @max_limit, @default_limit)

  # `totals` always covers the whole `period`; `buckets` is a series and stays capped, because a
  # year at `hour` granularity is nearly nine thousand of them. The default is therefore derived
  # from the window rather than fixed, so with no parameters at all the series adds up to the
  # totals instead of quietly showing 60 days of a 90-day figure. An explicit `limit`, or a
  # window too long for the cap, can still make the two differ - which is what `period` is for.
  defp bucket_limit(params, filters) do
    case integer(params["limit"]) do
      nil -> filters |> buckets_in_window(params) |> clamp(1, @max_limit, 60)
      given -> clamp(given, 1, @max_limit, 60)
    end
  end

  @seconds_per_bucket %{hour: 3_600, day: 86_400, week: 604_800, month: 2_592_000, year: 31_536_000}

  defp buckets_in_window(filters, params) do
    with from when is_integer(from) <- filters[:from],
         {:ok, granularity} <- granularity(params) do
      to = filters[:to] || System.system_time(:second)
      ceil((to - from) / Map.fetch!(@seconds_per_bucket, granularity)) + 1
    else
      _ -> 60
    end
  end

  defp clamp(nil, _min, _max, default), do: default
  defp clamp(value, min, max, _default), do: value |> max(min) |> min(max)

  defp paginate(rows, limit) do
    if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}
  end

  # The cursor for the next page: the id of the oldest row on this one, which the next request
  # passes back as `cursor`. Null when there is no next page.
  defp next_cursor([], _more?), do: nil
  defp next_cursor(_page, false), do: nil
  defp next_cursor(page, true), do: page |> List.last() |> Map.get("id")

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  defp sum(entries) do
    Enum.reduce(entries, zero(), fn e, acc ->
      %{
        count: acc.count + 1,
        in: acc.in + e["in"],
        out: acc.out + e["out"],
        total: acc.total + e["in"] + e["out"],
        list: acc.list + e["list"],
        cost: acc.cost + e["cost"],
        billable: acc.billable + e["billable"]
      }
    end)
  end

  defp zero, do: %{count: 0, in: 0, out: 0, total: 0, list: 0.0, cost: 0.0, billable: 0.0}

  defp error(conn, :not_found), do: send_error(conn, 404, "run not found")

  defp error(conn, :project_out_of_scope),
    do: send_error(conn, 403, "this token cannot read that project's usage")

  defp error(conn, :unknown_granularity),
    do: send_error(conn, 400, "granularity must be one of: hour, day, week, month, year")

  defp error(conn, :model_not_a_run_filter),
    do: send_error(conn, 400, "model is not a filter on runs - use /v1/usage/events")

  defp error(conn, :run_id_not_a_run_filter),
    do: send_error(conn, 400, "to read one run, use /v1/usage/runs/<id>")

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"message" => message, "type" => "pepe_error"}})
  end
end
