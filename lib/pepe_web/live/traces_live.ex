defmodule PepeWeb.TracesLive do
  @moduledoc """
  Traces section: a durable record of recent agent runs across every surface. The list
  shows each run's outcome, timing and the tools it called; opening one replays the whole
  run step by step (the prompt, each tool call with its arguments and result, failovers,
  token usage and the final reply) so you can see exactly what an agent did.

  Read-only over `Pepe.Trace`; nothing here re-executes a run.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Pricing
  alias Pepe.Trace
  alias Pepe.Usage

  @per_page 25
  @cap 1000

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Traces",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       selected: nil,
       f_agent: "",
       f_source: "",
       f_outcome: "",
       f_from: "",
       f_to: "",
       page: 1
     )
     |> load_list()}
  end

  # Pull the raw traces once; filtering and paging happen in memory over this list.
  defp load_list(socket) do
    scope = socket.assigns.scope
    scopes = if scope == "all", do: Trace.scopes(), else: [scope]

    traces =
      scopes
      |> Enum.flat_map(fn s -> Enum.map(Trace.recent(s, @cap), &Map.put(&1, "scope", s)) end)
      |> Enum.sort_by(& &1["at"], :desc)
      |> Enum.take(@cap)

    socket
    |> assign(
      all_traces: traces,
      agents: agent_options(traces),
      sources: source_options(traces),
      models: Config.models() |> Map.new(&{&1.name, &1}),
      price_cache: Pricing.load_cache()
    )
    |> apply_view()
  end

  # Total {input, output} tokens across a run's model calls.
  defp run_tokens(t) do
    Enum.reduce(t["usage"] || [], {0, 0}, fn u, {i, o} -> {i + (u["in"] || 0), o + (u["out"] || 0)} end)
  end

  # Provider cost of a run, summing each model call at its price (missing price -> 0).
  defp run_cost(t, models, cache) do
    Enum.reduce(t["usage"] || [], 0.0, fn u, acc ->
      {ip, op} = Usage.price_for(u["model"], models, cache)
      acc + Pricing.cost(u["in"] || 0, u["out"] || 0, ip, op)
    end)
  end

  # Recompute the filtered slice and paging metadata from the current filters + page.
  defp apply_view(socket) do
    a = socket.assigns
    filtered = filter_traces(a.all_traces, a.f_agent, a.f_source, a.f_outcome, a.f_from, a.f_to)
    total = length(filtered)
    pages = max(1, ceil(total / @per_page))
    page = a.page |> min(pages) |> max(1)

    assign(socket,
      total: total,
      pages: pages,
      page: page,
      page_from: (total == 0 && 0) || (page - 1) * @per_page + 1,
      page_to: min(page * @per_page, total),
      traces: Enum.slice(filtered, (page - 1) * @per_page, @per_page)
    )
  end

  defp filter_traces(traces, agent, source, outcome, from, to) do
    from_unix = day_start(from)
    to_unix = day_end(to)

    Enum.filter(traces, &trace_matches?(&1, agent, source, outcome, from_unix, to_unix))
  end

  defp trace_matches?(t, agent, source, outcome, from_unix, to_unix) do
    (agent == "" or t["agent"] == agent) and
      (source == "" or trace_source(t) == source) and
      outcome_matches?(t["outcome"], outcome) and
      within?(t["at"], from_unix, to_unix)
  end

  defp within?(at, from_unix, to_unix) do
    (is_nil(from_unix) or (is_integer(at) and at >= from_unix)) and
      (is_nil(to_unix) or (is_integer(at) and at <= to_unix))
  end

  # The trigger of a run: an explicit source, or derived from the session key (older traces).
  defp trace_source(t), do: t["source"] || Trace.source_from_session(t["session"])

  defp outcome_matches?(_o, ""), do: true
  defp outcome_matches?(o, kind) when is_map(o), do: o["kind"] == kind
  defp outcome_matches?(_o, _kind), do: false

  defp agent_options(traces) do
    traces |> Enum.map(& &1["agent"]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()
  end

  defp source_options(traces) do
    traces |> Enum.map(&trace_source/1) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="traces" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🧵"
          title={(@selected && gettext("Trace")) || gettext("Traces")}
          desc={
            (@selected && gettext("Replay of one run, step by step.")) ||
              gettext("The last runs across every surface: the tools each called, how it ended and how long it took. Open one to replay it.")
          }
        >
          <button :if={@selected} phx-click="close" class={btn_ghost()}>{gettext("← Back")}</button>
          <button :if={!@selected} phx-click="refresh" class={btn_ghost()}>{gettext("Refresh")}</button>
        </.view_header>

        <div class="flex min-h-0 flex-1 flex-col">
          <.filter_bar
            :if={!@selected}
            agents={@agents}
            sources={@sources}
            f_agent={@f_agent}
            f_source={@f_source}
            f_outcome={@f_outcome}
            f_from={@f_from}
            f_to={@f_to}
          />
          <div class="flex-1 overflow-y-auto p-6">
            <.trace_list :if={!@selected} traces={@traces} total={@total} models={@models} cache={@price_cache} />
            <.detail :if={@selected} trace={@selected} models={@models} cache={@price_cache} />
          </div>
          <.pager
            :if={!@selected and @total > 0}
            page={@page}
            pages={@pages}
            from={@page_from}
            to={@page_to}
            total={@total}
          />
        </div>
      </main>
    </div>
    """
  end

  attr :agents, :list, required: true
  attr :sources, :list, required: true
  attr :f_agent, :string, required: true
  attr :f_source, :string, required: true
  attr :f_outcome, :string, required: true
  attr :f_from, :string, required: true
  attr :f_to, :string, required: true

  defp filter_bar(assigns) do
    ~H"""
    <form id="trace-filters" phx-change="filter" class="flex flex-wrap items-end gap-3 border-b border-zinc-800 px-6 py-3">
      <div>
        <label class="mb-1 block text-xs font-medium text-zinc-500">{gettext("Agent")}</label>
        <select name="agent" class={[fld(), "py-1.5"]}>
          <option value="">{gettext("All agents")}</option>
          <option :for={a <- @agents} value={a} selected={a == @f_agent}>{a}</option>
        </select>
      </div>
      <div>
        <label class="mb-1 block text-xs font-medium text-zinc-500">{gettext("Source")}</label>
        <select name="source" class={[fld(), "py-1.5"]}>
          <option value="">{gettext("Any source")}</option>
          <option :for={s <- @sources} value={s} selected={s == @f_source}>{source_label(s)}</option>
        </select>
      </div>
      <div>
        <label class="mb-1 block text-xs font-medium text-zinc-500">{gettext("Outcome")}</label>
        <select name="outcome" class={[fld(), "py-1.5"]}>
          <option value="" selected={@f_outcome == ""}>{gettext("Any outcome")}</option>
          <option value="ok" selected={@f_outcome == "ok"}>{gettext("Ok")}</option>
          <option value="error" selected={@f_outcome == "error"}>{gettext("Error")}</option>
        </select>
      </div>
      <div>
        <label class="mb-1 block text-xs font-medium text-zinc-500">{gettext("When")}</label>
        <input type="date" name="from" value={@f_from} class={[fld(), "py-1.5"]} />
      </div>
      <div>
        <label class="mb-1 block text-xs font-medium text-zinc-500">{gettext("Until")}</label>
        <input type="date" name="to" value={@f_to} class={[fld(), "py-1.5"]} />
      </div>
      <button
        :if={@f_agent != "" or @f_source != "" or @f_outcome != "" or @f_from != "" or @f_to != ""}
        type="button"
        phx-click="clear_filters"
        class={[btn_ghost(), "mb-0.5"]}
      >
        {gettext("Clear")}
      </button>
    </form>
    """
  end

  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :from, :integer, required: true
  attr :to, :integer, required: true
  attr :total, :integer, required: true

  defp pager(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-t border-zinc-800 px-6 py-3 text-sm text-zinc-500">
      <span>{gettext("%{from}-%{to} of %{total}", from: @from, to: @to, total: @total)}</span>
      <div class="flex items-center gap-2">
        <button phx-click="page" phx-value-page={@page - 1} disabled={@page <= 1} class={[btn_ghost(), @page <= 1 && "opacity-40"]}>
          {gettext("← Previous")}
        </button>
        <span class="tabular-nums text-zinc-400">{@page} / {@pages}</span>
        <button phx-click="page" phx-value-page={@page + 1} disabled={@page >= @pages} class={[btn_ghost(), @page >= @pages && "opacity-40"]}>
          {gettext("Next →")}
        </button>
      </div>
    </div>
    """
  end

  attr :traces, :list, required: true
  attr :total, :integer, required: true
  attr :models, :map, required: true
  attr :cache, :map, required: true

  defp trace_list(assigns) do
    ~H"""
    <div :if={@total == 0} class="rounded-xl border border-dashed border-zinc-800 p-10 text-center text-zinc-500">
      {gettext("No runs match these filters. Every agent run, from any surface, shows up here.")}
    </div>
    <div :if={@traces != []} class="overflow-x-auto rounded-xl border border-zinc-800">
      <table class="w-full min-w-[720px] text-[15px]">
        <thead class="bg-zinc-900/60 text-left text-sm text-zinc-500">
          <tr>
            <th class="px-3 py-2 font-medium">{gettext("When")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Agent")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Source")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Request")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Outcome")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Tools")}</th>
            <th class="px-3 py-2 text-right font-medium">{gettext("Cost")}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={t <- @traces} class="border-t border-zinc-800/70 hover:bg-zinc-800/40">
            <td class="whitespace-nowrap px-3 py-2 font-mono text-sm text-zinc-400">{fmt_at(t["at"])}</td>
            <td class="px-3 py-2">
              <span class="text-zinc-200">{t["agent"]}</span>
            </td>
            <td class="whitespace-nowrap px-3 py-2">
              <span class="rounded-full bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300">{source_label(trace_source(t))}</span>
            </td>
            <td class="px-3 py-2 text-sm text-zinc-400">
              <div class="max-w-[22rem] truncate">{prompt_snippet(t["prompt"])}</div>
            </td>
            <td class="px-3 py-2"><.outcome_badge outcome={t["outcome"]} /></td>
            <td class="px-3 py-2 text-sm text-zinc-400">{tools_label(t["tools"])}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right">
              <% {ti, to} = run_tokens(t) %>
              <% cost = run_cost(t, @models, @cache) %>
              <div :if={cost > 0} class="text-sm text-zinc-300" title={gettext("Estimated provider cost of this run, from its token usage.")}>
                {fmt_cost(cost)}
              </div>
              <div
                :if={ti + to > 0}
                class="text-xs text-zinc-600"
                title={gettext("Input tokens → output tokens (%{in} in, %{out} out).", in: ti, out: to)}
              >
                {fmt_tokens(ti)} → {fmt_tokens(to)}
              </div>
              <span :if={ti + to == 0} class="text-sm text-zinc-600" title={gettext("No token usage was recorded for this run.")}>–</span>
            </td>
            <td class="px-3 py-2 text-right">
              <button phx-click="open" phx-value-scope={t["scope"]} phx-value-id={t["id"]} class={btn_ghost()}>
                {gettext("Replay")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :trace, :map, required: true
  attr :models, :map, required: true
  attr :cache, :map, required: true

  defp detail(assigns) do
    {tin, tout} = run_tokens(assigns.trace)
    assigns = assign(assigns, tokens_in: tin, tokens_out: tout, cost: run_cost(assigns.trace, assigns.models, assigns.cache))

    ~H"""
    <div class="mx-auto max-w-3xl space-y-5">
      <div class={card()}>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <div class="text-lg font-semibold">{@trace["agent"]}</div>
            <div class="mt-0.5 text-sm text-zinc-500">
              {fmt_at(@trace["at"])} · {fmt_ms(@trace["ms"])}
              <span class="ml-1">· {source_label(trace_source(@trace))}</span>
            </div>
          </div>
          <.outcome_badge outcome={@trace["outcome"]} />
        </div>

        <div :if={@tokens_in + @tokens_out > 0} class="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm">
          <span class="text-zinc-500">{gettext("Input")}: <span class="text-zinc-300">{@tokens_in}</span> {gettext("tokens")}</span>
          <span class="text-zinc-500">{gettext("Output")}: <span class="text-zinc-300">{@tokens_out}</span> {gettext("tokens")}</span>
          <span class="text-zinc-500">{gettext("Cost")}: <span class="text-zinc-300">{fmt_cost(@cost)}</span></span>
        </div>
        <div :if={@trace["prompt"]} class="mt-3 rounded-lg bg-zinc-950/60 p-3">
          <div class="mb-1 text-xs font-semibold uppercase tracking-wider text-zinc-600">{gettext("Prompt")}</div>
          <div class="whitespace-pre-wrap break-words text-[15px] text-zinc-300">{@trace["prompt"]}</div>
        </div>
      </div>

      <ol class="relative space-y-3 border-l border-zinc-800 pl-5">
        <li :for={ev <- @trace["events"]} class="relative">
          <span class="absolute -left-[26px] top-1 flex h-5 w-5 items-center justify-center rounded-full bg-zinc-900 text-xs ring-1 ring-zinc-700">
            {event_icon(ev)}
          </span>
          <.event ev={ev} />
        </li>
        <li :if={@trace["events"] == []} class="text-sm text-zinc-500">{gettext("This run ended before any step ran.")}</li>
      </ol>
    </div>
    """
  end

  attr :ev, :map, required: true

  defp event(%{ev: %{"t" => "tool_call"}} = assigns) do
    ~H"""
    <div>
      <div class="text-[15px] font-medium text-orange-300">{gettext("Tool")} · {@ev["name"]}</div>
      <pre class="mt-1 overflow-x-auto rounded-lg bg-zinc-950/70 p-2.5 text-xs text-zinc-400"><code>{@ev["args"]}</code></pre>
    </div>
    """
  end

  defp event(%{ev: %{"t" => "tool_result"}} = assigns) do
    ~H"""
    <div>
      <div class="text-sm text-zinc-500">{gettext("Result")} · {@ev["name"]}</div>
      <pre class="mt-1 overflow-x-auto rounded-lg bg-zinc-950/70 p-2.5 text-xs text-zinc-400"><code>{@ev["out"]}</code></pre>
    </div>
    """
  end

  defp event(%{ev: %{"t" => "assistant"}} = assigns) do
    ~H"""
    <div>
      <div class="text-sm text-zinc-500">{gettext("Assistant")}</div>
      <div class="mt-1 whitespace-pre-wrap break-words text-[15px] text-zinc-200">{@ev["text"]}</div>
    </div>
    """
  end

  defp event(%{ev: %{"t" => "tool_denied"}} = assigns) do
    ~H"""
    <div class="text-[15px] text-yellow-400">
      {gettext("Blocked")} · {@ev["name"]}
      <span :if={@ev["reason"]} class="text-zinc-400">— {@ev["reason"]}</span>
    </div>
    """
  end

  defp event(%{ev: %{"t" => "failover"}} = assigns) do
    ~H"""
    <div class="text-sm text-zinc-400">{gettext("Failover")}: {@ev["from"]} → {@ev["to"]}</div>
    """
  end

  defp event(%{ev: %{"t" => "triage"}} = assigns) do
    ~H"""
    <div class="text-sm text-zinc-400">
      {gettext("Triage")} ({@ev["triage_model"]}): {triage_verdict_label(@ev["verdict"])}
      <span :if={@ev["chosen_model"]}>→ {@ev["chosen_model"]}</span>
    </div>
    """
  end

  defp event(%{ev: %{"t" => "hook"}} = assigns) do
    ~H"""
    <div class="text-sm text-zinc-400">{gettext("Hook")} · {@ev["name"]} ({@ev["stage"]}): {hook_result_label(@ev)}</div>
    """
  end

  defp event(%{ev: %{"t" => "usage"}} = assigns) do
    ~H"""
    <div class="text-sm text-zinc-500">
      {@ev["model"]} · {gettext("in")} {@ev["in"]} · {gettext("out")} {@ev["out"]} {gettext("tokens")}
    </div>
    """
  end

  defp event(%{ev: %{"t" => "error"}} = assigns) do
    ~H"""
    <div class="text-[15px] text-red-400">{gettext("Error")}: {@ev["reason"]}</div>
    """
  end

  defp event(assigns), do: ~H""

  defp triage_verdict_label("simple"), do: gettext("simple")
  defp triage_verdict_label("complex"), do: gettext("complex")
  defp triage_verdict_label("failed"), do: gettext("unreachable, skipped")
  defp triage_verdict_label(v), do: v

  defp hook_result_label(%{"changed" => false}), do: gettext("no change")

  defp hook_result_label(%{"changed" => true, "entries" => n}) when is_integer(n) and n > 0,
    do: gettext("changed, %{n} reversible", n: n)

  defp hook_result_label(%{"changed" => true}), do: gettext("changed")

  attr :outcome, :map, default: nil

  defp outcome_badge(%{outcome: %{"kind" => "error"} = o} = assigns) do
    assigns = assign(assigns, reason: o["reason"])

    ~H"""
    <span class="rounded-full bg-red-500/15 px-2.5 py-1 text-xs font-medium text-red-400" title={@reason}>{gettext("error")}</span>
    """
  end

  defp outcome_badge(%{outcome: %{"kind" => "ok"}} = assigns) do
    ~H"""
    <span class="rounded-full bg-green-500/15 px-2.5 py-1 text-xs font-medium text-green-400">{gettext("ok")}</span>
    """
  end

  defp outcome_badge(assigns) do
    ~H"""
    <span class="rounded-full bg-zinc-700/40 px-2.5 py-1 text-xs text-zinc-400">–</span>
    """
  end

  @impl true
  def handle_event("open", %{"scope" => scope, "id" => id}, socket) do
    {:noreply, assign(socket, selected: Trace.get(scope, id))}
  end

  def handle_event("close", _p, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("refresh", _p, socket), do: {:noreply, load_list(socket)}

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(
       f_agent: params["agent"] || "",
       f_source: params["source"] || "",
       f_outcome: params["outcome"] || "",
       f_from: params["from"] || "",
       f_to: params["to"] || "",
       page: 1
     )
     |> apply_view()}
  end

  def handle_event("clear_filters", _p, socket) do
    {:noreply,
     socket
     |> assign(f_agent: "", f_source: "", f_outcome: "", f_from: "", f_to: "", page: 1)
     |> apply_view()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(page: String.to_integer(page)) |> apply_view()}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/traces")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  # --- formatting helpers ------------------------------------------------------------

  defp source_label("cron"), do: gettext("Schedule")
  defp source_label("eval"), do: gettext("Eval")
  defp source_label("heartbeat"), do: gettext("Heartbeat")
  defp source_label("manual"), do: gettext("Manual")
  defp source_label("cli"), do: "CLI"
  defp source_label("api"), do: "API"
  defp source_label("telegram"), do: "Telegram"
  defp source_label(other) when is_binary(other), do: String.capitalize(other)
  defp source_label(_), do: gettext("Manual")

  defp prompt_snippet(p) when is_binary(p) do
    case String.trim(p) do
      "" -> "–"
      s -> s |> String.replace(~r/\s+/u, " ") |> String.slice(0, 80)
    end
  end

  defp prompt_snippet(_), do: "–"

  defp tools_label([]), do: "–"

  defp tools_label(names) when is_list(names) do
    names
    |> Enum.frequencies()
    |> Enum.map_join(", ", fn
      {n, 1} -> n
      {n, c} -> "#{n} ×#{c}"
    end)
  end

  defp tools_label(_), do: "–"

  defp fmt_tokens(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp fmt_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_tokens(_), do: "0"

  defp fmt_cost(c) when is_number(c) and c > 0 do
    decimals =
      cond do
        c >= 1 -> 2
        c >= 0.01 -> 4
        true -> 6
      end

    "US$ " <> :erlang.float_to_binary(c * 1.0, decimals: decimals)
  end

  defp fmt_cost(_), do: "–"

  defp fmt_ms(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)} s"
  defp fmt_ms(ms) when is_integer(ms), do: "#{ms} ms"
  defp fmt_ms(_), do: "–"

  defp fmt_at(at) when is_integer(at), do: local_datetime(at, "%Y-%m-%d %H:%M:%S")
  defp fmt_at(_), do: "–"

  defp day_start(date), do: day_bound(date, ~T[00:00:00])
  defp day_end(date), do: day_bound(date, ~T[23:59:59])

  defp day_bound("", _time), do: nil

  defp day_bound(date, time) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_unix()
      _ -> nil
    end
  end

  defp event_icon(%{"t" => "tool_call"}), do: "🔧"
  defp event_icon(%{"t" => "tool_result"}), do: "↳"
  defp event_icon(%{"t" => "assistant"}), do: "💬"
  defp event_icon(%{"t" => "tool_denied"}), do: "🚫"
  defp event_icon(%{"t" => "failover"}), do: "⇄"
  defp event_icon(%{"t" => "triage"}), do: "🧭"
  defp event_icon(%{"t" => "hook"}), do: "🛡"
  defp event_icon(%{"t" => "usage"}), do: "◷"
  defp event_icon(%{"t" => "error"}), do: "⚠"
  defp event_icon(_), do: "·"
end
