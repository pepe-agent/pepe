defmodule PepeWeb.OverviewLive do
  @moduledoc """
  The dashboard home: an at-a-glance overview for whoever runs Pepe - live sessions,
  messages and token spend this month, which project spends the most, and how many
  agents/models/channels/automations are configured. Scope-aware via the sidebar.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Runtime.Stats
  alias Pepe.Usage.Trends

  # "in + out" says nothing about cost when most of the input was re-read from the provider's
  # cache; say so, since that is what makes a big token count cheaper than it looks.
  defp tokens_sub(%{cached: cached, in: input, out: out}) when cached > 0 and input > 0,
    do:
      gettext("%{fresh} new, %{cached} from cache (billed less), %{out} out",
        fresh: tokens(input - cached),
        cached: tokens(cached),
        out: tokens(out)
      )

  defp tokens_sub(_), do: gettext("in + out")

  # The dashed line on the success chart. A fixed reference, not a setting: 95% is where a
  # support agent starts to feel dependable.
  @success_goal 95

  @impl true
  # How often the runtime footprint refreshes. CPU is a delta between two scheduler
  # samples, so the first tick is what makes it knowable at all.
  @footprint_ms 2000

  def mount(params, _session, socket) do
    scope = params["scope"] || "all"
    if connected?(socket), do: :timer.send_interval(@footprint_ms, self(), :footprint)

    {:ok,
     socket
     |> assign(
       page_title: "Pepe: " <> gettext("Overview"),
       scope: scope,
       projects: Config.project_slugs(),
       new_project: false,
       footprint: Stats.footprint(),
       cpu: nil,
       sched: Stats.sample(),
       tab: tab_from(params["tab"]),
       trend_period: :week,
       success_goal: @success_goal
     )
     |> load()}
  end

  @impl true
  def handle_info(:footprint, socket) do
    curr = Stats.sample()

    {:noreply,
     assign(socket,
       footprint: Stats.footprint(),
       cpu: Stats.utilization(socket.assigns.sched, curr),
       sched: curr
     )}
  end

  # "3d 4h" / "2h 15m" / "48s" - the coarsest unit that still says something.
  defp uptime(sec) when sec >= 86_400, do: "#{div(sec, 86_400)}d #{div(rem(sec, 86_400), 3600)}h"
  defp uptime(sec) when sec >= 3600, do: "#{div(sec, 3600)}h #{div(rem(sec, 3600), 60)}m"
  defp uptime(sec) when sec >= 60, do: "#{div(sec, 60)}m"
  defp uptime(sec), do: "#{sec}s"

  defp load(socket) do
    scope = socket.assigns.scope
    scope_arg = if scope == "all", do: :all, else: scope

    month = Pepe.Usage.summary(scope_arg, :month)
    days = Pepe.Usage.summary(scope_arg, :day, limit: 14)

    assign(socket,
      month: month,
      days: days.buckets,
      trend: Trends.compare(scope_arg, socket.assigns.trend_period),
      weeks: Trends.weekly(scope_arg, 8),
      activity: Trends.activity(scope_arg, 30),
      live_sessions: scoped_live_sessions(scope),
      counts: %{
        agents: length(scoped_agents(Config.agents(), scope)),
        projects: length(Config.project_slugs()),
        models: length(scoped_models(Config.models(), scope)),
        channels: scoped_channels(scope),
        automations: scoped_automations(scope)
      }
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="overview" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header active="overview"
          icon="🏠"
          title={gettext("Overview")}
          desc={gettext("Live activity and this month's usage across %{scope}.", scope: scope_label(@scope))}
        />

        <div class="page-body flex-1 space-y-6 overflow-y-auto px-4 pb-8 pt-1 sm:px-8 xl:px-14">
          <div class="flex flex-wrap items-end justify-between gap-3 border-b border-zinc-800">
            <div role="tablist" class="-mb-px flex gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              <button
                :for={{tab, label} <- overview_tabs()}
                type="button"
                role="tab"
                phx-click="overview_tab"
                phx-value-tab={tab}
                aria-selected={to_string(@tab == tab)}
                class={[
                  "shrink-0 border-b-2 px-4 py-2.5 text-base font-medium transition focus-visible:outline-offset-[-3px]",
                  (@tab == tab && "border-orange-400 text-orange-300") || "border-transparent text-zinc-400 hover:text-zinc-100"
                ]}
              >
                {label}
              </button>
            </div>
            <%!-- Trends and health compare the same two periods, so one switch serves both. It keeps its space on the other tabs (invisible, not removed), so the tab bar never changes height and nothing below it moves. --%>
            <div role="group" aria-label={gettext("Compare with")} inert={@tab not in ["trends", "health"]}
              class={["mb-2 inline-flex rounded-[10px] border border-white/[.12] p-0.5 text-[13.5px]", @tab not in ["trends", "health"] && "invisible"]}>
              <button :for={p <- [:week, :month]} type="button" phx-click="trend_period" phx-value-period={p} aria-pressed={to_string(@trend_period == p)}
                class={["rounded-[8px] px-3 py-1.5 transition", @trend_period == p && "bg-white/[.08] text-zinc-50", @trend_period != p && "text-zinc-500 hover:text-zinc-200"]}>
                {if p == :week, do: gettext("Week"), else: gettext("Month")}
              </button>
            </div>
          </div>

          <div :if={@tab == "summary"} class="space-y-6">
          <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <.stat label={gettext("Live sessions")} value={Integer.to_string(@live_sessions)} sub={gettext("Open right now")} />
            <.stat label={gettext("Messages this month")} value={tokens(@month.totals.count)} sub={gettext("model calls")} />
            <.stat label={gettext("Tokens this month")} value={tokens(@month.totals.total)} sub={tokens_sub(@month.totals)} />
            <%!-- Cost is what we actually paid: token prices for API connections, plus the flat
                  monthly fee of each subscription that served a call. Not the tokens a
                  subscription served priced as if they had been bought. --%>
            <.stat label={gettext("To bill this month")} value={money(@month.totals.billable, @month.currency)} sub={gettext("cost %{c} (what you pay the provider)", c: money(@month.totals.cost + @month.subscriptions, @month.currency))} accent="text-orange-400" />
          </div>

          <%!-- What the runtime costs to run, measured live rather than asserted. --%>
          <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
            <div class="mb-3 flex items-baseline justify-between">
              <span class="text-sm font-medium text-zinc-300">{gettext("Runtime footprint")}</span>
              <span class="text-xs text-zinc-600">{gettext("up %{t}", t: uptime(@footprint.uptime_seconds))}</span>
            </div>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <.mini label={gettext("Memory")} value={"#{@footprint.memory_mb} MB"} />
              <.mini label={gettext("CPU")} value={if @cpu, do: "#{@cpu}%", else: "-"} />
              <.mini label={gettext("Conversations")} value={@footprint.sessions} />
              <.mini
                label={gettext("Processes")}
                value={@footprint.processes}
                hint={gettext("internal tasks the runtime is juggling")}
              />
            </div>
          </div>

          <div>
            <div class="mb-2 font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{gettext("Configured")}</div>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
              <.mini label={gettext("Agents")} value={@counts.agents} />
              <.mini label={gettext("Projects")} value={@counts.projects} />
              <.mini label={gettext("Models")} value={@counts.models} />
              <.mini label={gettext("Channels")} value={@counts.channels} />
              <.mini label={gettext("Automations")} value={@counts.automations} />
            </div>
          </div>
          </div>

          <section :if={@tab == "trends"} aria-label={gettext("Trends")} class="space-y-3">
            <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <.compare_tile label={gettext("Spend")} value={money(@trend.current.billable, @trend.currency)} change={@trend.change.billable}
                versus={versus(@trend_period)} before={money(@trend.previous.billable, @trend.currency)} />
              <.compare_tile label={gettext("Tokens")} value={tokens(@trend.current.tokens)} change={@trend.change.tokens}
                versus={versus(@trend_period)} before={tokens(@trend.previous.tokens)} />
              <.compare_tile label={gettext("Runs")} value={tokens(@trend.current.runs)} change={@trend.change.runs}
                versus={versus(@trend_period)} before={tokens(@trend.previous.runs)} />
              <.compare_tile label={gettext("Errors")} value={tokens(@trend.current.errors)} change={@trend.change.errors} tone={:bad_up}
                versus={versus(@trend_period)} before={tokens(@trend.previous.errors)} />
            </div>

            <div class="grid gap-3 lg:grid-cols-2">
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Spend by week")}</div>
                <.chart id="chart-spend" kind="line" unit="money" currency={money_symbol(@month.currency)} label={gettext("Spend by week")}
                  labels={week_labels(@weeks)}
                  series={[%{name: gettext("Spend"), values: Enum.map(@weeks, &Float.round(&1.billable * 1.0, 4)), tone: "gold"}]} />
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Runs and errors by week")}</div>
                <.chart id="chart-runs" kind="bar" label={gettext("Runs and errors by week")}
                  labels={week_labels(@weeks)}
                  series={[%{name: gettext("Runs"), values: Enum.map(@weeks, & &1.runs), tone: "teal"}, %{name: gettext("Errors"), values: Enum.map(@weeks, & &1.errors), tone: "red"}]} />
              </div>
            </div>
          </section>


          <section :if={@tab == "health"} aria-label={gettext("How it's going")} class="space-y-3">
            <div class="grid grid-cols-2 gap-3 lg:grid-cols-3">
              <.compare_tile label={gettext("Success rate")} value={percent(@trend.current.success)} change={@trend.change.success} tone={:good_up} delta_unit={" " <> gettext("pts")}
                versus={versus(@trend_period)} before={percent(@trend.previous.success)} />
              <.compare_tile label={gettext("Typical reply time")} value={latency(@trend.current.ms)} change={@trend.change.ms} tone={:bad_up}
                versus={versus(@trend_period)} before={latency(@trend.previous.ms)} />
              <.compare_tile label={gettext("Saved by cache")} value={money(@trend.current.saved, @trend.currency)} change={@trend.change.saved} tone={:good_up}
                versus={versus(@trend_period)} before={money(@trend.previous.saved, @trend.currency)} />
            </div>

            <div class="grid gap-3 lg:grid-cols-2">
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Success rate by week")}</div>
                <.chart id="chart-success" kind="line" unit="percent" label={gettext("Success rate by week")} goal={%{value: @success_goal, label: "#{@success_goal}%"}}
                  labels={week_labels(@weeks)}
                  series={[%{name: gettext("Success rate"), values: Enum.map(@weeks, & &1.success), tone: "teal"}]} />
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Input served from the cache")}</div>
                <.chart id="chart-cache" kind="line" unit="percent" label={gettext("Input served from the cache")}
                  labels={week_labels(@weeks)}
                  series={[%{name: gettext("From cache"), values: Enum.map(@weeks, & &1.cached_share), tone: "gold"}]} />
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Reply time by week")}</div>
                <.chart id="chart-latency" kind="line" unit="seconds" label={gettext("Reply time by week")}
                  labels={week_labels(@weeks)}
                  series={[%{name: gettext("Typical reply time"), values: Enum.map(@weeks, &seconds(&1.ms)), tone: "slate"}]} />
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Busiest hours (last 30 days)")}</div>
                <.chart id="chart-hours" kind="bar" label={gettext("Busiest hours (last 30 days)")}
                  labels={Enum.map(0..23, &String.pad_leading(Integer.to_string(&1), 2, "0"))}
                  series={[%{name: gettext("Runs"), values: @activity.hours, tone: "gold"}]} />
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Where conversations come from")}</div>
                <.chart id="chart-sources" kind="bar" label={gettext("Where conversations come from")}
                  labels={Enum.map(@activity.sources, &elem(&1, 0))}
                  series={[%{name: gettext("Runs"), values: Enum.map(@activity.sources, &elem(&1, 1)), tone: "teal"}]} />
                <p :if={@activity.sources == []} class="pb-2 text-center text-sm text-zinc-600">{gettext("No runs yet")}</p>
              </div>
              <div class={card()}>
                <div class="mb-2 text-[14.5px] font-medium text-zinc-200">{gettext("Busiest agents (last 30 days)")}</div>
                <.chart id="chart-agents" kind="bar" label={gettext("Busiest agents (last 30 days)")}
                  labels={Enum.map(@activity.agents, &elem(&1, 0))}
                  series={[%{name: gettext("Runs"), values: Enum.map(@activity.agents, &elem(&1, 1)), tone: "gold"}]} />
                <p :if={@activity.agents == []} class="pb-2 text-center text-sm text-zinc-600">{gettext("No runs yet")}</p>
              </div>
            </div>
          </section>


          <div :if={@tab == "usage"} class="space-y-6">
          <div class="grid gap-6 lg:grid-cols-2">
            <div>
              <div class="mb-2 font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{gettext("Activity (tokens, last 14 days)")}</div>
              <div class={card()}>
                <.chart id="chart-activity" kind="line" unit="tokens" label={gettext("Activity (tokens, last 14 days)")} class="h-40"
                  labels={Enum.map(@days, & &1.key)}
                  series={[%{name: gettext("Tokens"), values: Enum.map(@days, & &1.total), tone: "slate"}]} />
                <p :if={@days == []} class="pb-2 text-center text-sm text-zinc-600">{gettext("No usage yet")}</p>
              </div>
            </div>

            <div>
              <div class="mb-2 font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{gettext("Top projects by spend")}</div>
              <div class="space-y-1 rounded-xl border border-zinc-800 p-2">
                <div :for={c <- Enum.take(@month.by_project, 6)} class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-base">
                  <span class="truncate text-zinc-300">{c.key}</span>
                  <span class="flex shrink-0 items-center gap-3 text-sm">
                    <span class="text-zinc-500">{tokens(c.total)}</span>
                    <span class="w-20 text-right font-medium">{money(c.billable, @month.currency)}</span>
                  </span>
                </div>
                <p :if={@month.by_project == []} class="px-2 py-3 text-center text-sm text-zinc-600">{gettext("No usage yet")}</p>
              </div>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <.breakdown title={gettext("Top models")} currency={@month.currency} rows={Enum.take(@month.by_model, 6)} />
            <.breakdown title={gettext("Top agents")} currency={@month.currency} rows={Enum.take(@month.by_agent, 6)} />
          </div>
          </div>

        </div>
      </main>
    </div>
    """
  end

  attr :label, :string, required: true
  # A count, or a formatted reading like "86.4 MB" / "2.1%" / "-".
  attr :value, :any, required: true
  # Plain-language gloss for a reading whose label means nothing on its own (the raw BEAM
  # process count). Rendered, not a `title=`: a tooltip is invisible on a touch screen.
  attr :hint, :string, default: nil

  defp mini(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 px-3 py-2">
      <div class="font-mono text-lg font-normal text-zinc-50">{@value}</div>
      <div class="text-xs text-zinc-500">{@label}</div>
      <div :if={@hint} class="mt-0.5 text-[12px] leading-tight text-zinc-600">{@hint}</div>
    </div>
    """
  end

  defp seconds(nil), do: nil
  defp seconds(ms), do: Float.round(ms / 1000, 2)

  defp percent(nil), do: "-"
  defp percent(rate), do: "#{trim(rate)}%"

  # Whole milliseconds under a second, seconds with one decimal above it.
  defp latency(nil), do: "-"
  defp latency(ms) when ms < 1000, do: "#{ms} ms"
  defp latency(ms), do: "#{trim(Float.round(ms / 1000, 1))} s"

  defp trim(n) when is_float(n), do: if(n == Float.round(n, 0), do: trunc(n), else: n)
  defp trim(n), do: n

  defp overview_tabs do
    [
      {"summary", gettext("Summary")},
      {"trends", gettext("Trends")},
      {"health", gettext("How it's going")},
      {"usage", gettext("Usage")}
    ]
  end

  defp tab_from(tab) when tab in ["summary", "trends", "health", "usage"], do: tab
  defp tab_from(_), do: "summary"

  defp versus(:week), do: gettext("last week")
  defp versus(:month), do: gettext("last month")

  # "2026-09-28" -> "09-28": the year adds nothing to an axis of eight weeks. The running week is
  # named for what it is, because it is the one bar that is not finished and looks like a drop.
  defp week_labels(weeks) do
    last = length(weeks) - 1

    weeks
    |> Enum.with_index()
    |> Enum.map(fn
      {_week, ^last} -> gettext("This week")
      {%{key: <<_year::binary-size(5), rest::binary>>}, _i} -> rest
      {%{key: key}, _i} -> key
    end)
  end

  # Everything below is counted within the selected project scope (a bare count
  # ignores which project is showing). `in_scope?` treats "all" as everything.
  defp scoped_live_sessions(scope) do
    Enum.count(SessionSupervisor.list(), fn key ->
      agent = session_agent(key)
      agent && in_scope?(agent, scope)
    end)
  end

  defp session_agent(key) do
    Pepe.Agent.Session.status(key).agent
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp scoped_channels(scope) do
    telegram = Enum.count(Config.telegram_bots(), &in_scope?(&1["agent"], scope))
    webhooks = Config.webhooks() |> Map.values() |> Enum.count(&in_scope?(&1["agent"], scope))
    telegram + webhooks
  end

  defp scoped_automations(scope) do
    crons = Enum.count(Config.crons(), &in_scope?(&1.agent, scope))
    watches = Enum.count(Config.watches(), &in_scope?(&1.agent, scope))
    crons + watches
  end

  defp scope_label("all"), do: gettext("all scopes")
  defp scope_label("root"), do: gettext("the Principal scope")
  defp scope_label(project), do: project

  @impl true
  def handle_event("overview_tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, tab: tab_from(tab))}

  def handle_event("trend_period", %{"period" => period}, socket) when period in ["week", "month"],
    do: {:noreply, socket |> assign(trend_period: String.to_existing_atom(period)) |> load()}

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/overview")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}
end
