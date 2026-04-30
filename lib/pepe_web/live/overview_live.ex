defmodule PepeWeb.OverviewLive do
  @moduledoc """
  The dashboard home: an at-a-glance overview for whoever runs Pepe - live sessions,
  messages and token spend this month, which company spends the most, and how many
  agents/models/channels/automations are configured. Scope-aware via the sidebar.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Runtime.Stats

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
       page_title: "Pepe · Overview",
       scope: scope,
       companies: Config.companies(),
       new_company: false,
       footprint: Stats.footprint(),
       cpu: nil,
       sched: Stats.sample()
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
      live_sessions: scoped_live_sessions(scope),
      counts: %{
        agents: length(scoped_agents(Config.agents(), scope)),
        companies: length(Config.companies()),
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
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="overview" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🏠"
          title={gettext("Overview")}
          desc={gettext("Live activity and this month's usage across %{scope}.", scope: scope_label(@scope))}
        />

        <div class="flex-1 space-y-6 overflow-y-auto p-6">
          <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <.stat label={gettext("Live sessions")} value={Integer.to_string(@live_sessions)} sub={gettext("Open right now")} />
            <.stat label={gettext("Messages this month")} value={tokens(@month.totals.count)} sub={gettext("model calls")} />
            <.stat label={gettext("Tokens this month")} value={tokens(@month.totals.total)} sub={gettext("in + out")} />
            <.stat label={gettext("To bill this month")} value={money(@month.totals.billable, @month.currency)} sub={gettext("cost %{c}", c: money(@month.totals.cost, @month.currency))} accent />
          </div>

          <%!-- What the runtime costs to run, measured live rather than asserted. --%>
          <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 p-4">
            <div class="mb-3 flex items-baseline justify-between">
              <span class="text-sm font-medium text-zinc-300">{gettext("Runtime footprint")}</span>
              <span class="text-xs text-zinc-600">{gettext("up %{t}", t: uptime(@footprint.uptime_seconds))}</span>
            </div>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <.mini label={gettext("Memory")} value={"#{@footprint.memory_mb} MB"} />
              <.mini label={gettext("CPU")} value={if @cpu, do: "#{@cpu}%", else: "—"} />
              <.mini label={gettext("Conversations")} value={@footprint.sessions} />
              <.mini label={gettext("Processes")} value={@footprint.processes} />
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <.mini label={gettext("Agents")} value={@counts.agents} />
            <.mini label={gettext("Companies")} value={@counts.companies} />
            <.mini label={gettext("Models")} value={@counts.models} />
            <.mini label={gettext("Channels")} value={@counts.channels} />
            <.mini label={gettext("Automations")} value={@counts.automations} />
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <div>
              <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("Activity (last 14 days)")}</div>
              <div class="flex h-32 items-end gap-1 rounded-xl border border-zinc-800 p-3">
                <div :for={b <- @days} class="group relative flex-1" title={"#{b.key}: #{tokens(b.total)} tok"}>
                  <div class="w-full rounded-t bg-orange-600/70" style={"height: #{bar_pct(b.total, @days)}%"}></div>
                </div>
                <p :if={@days == []} class="m-auto text-sm text-zinc-600">{gettext("No usage yet")}</p>
              </div>
            </div>

            <div>
              <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("Top companies by spend")}</div>
              <div class="space-y-1 rounded-xl border border-zinc-800 p-2">
                <div :for={c <- Enum.take(@month.by_company, 6)} class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-[15px] hover:bg-zinc-800/50">
                  <span class="truncate text-zinc-300">{c.key}</span>
                  <span class="flex shrink-0 items-center gap-3 text-sm">
                    <span class="text-zinc-500">{tokens(c.total)}</span>
                    <span class="w-20 text-right font-medium">{money(c.billable, @month.currency)}</span>
                  </span>
                </div>
                <p :if={@month.by_company == []} class="px-2 py-3 text-center text-sm text-zinc-600">{gettext("No usage yet")}</p>
              </div>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-2">
            <.breakdown title={gettext("Top models")} currency={@month.currency} rows={Enum.take(@month.by_model, 6)} />
            <.breakdown title={gettext("Top agents")} currency={@month.currency} rows={Enum.take(@month.by_agent, 6)} />
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :accent, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class={card()}>
      <div class="text-sm text-zinc-500">{@label}</div>
      <div class={["mt-1 text-2xl font-semibold", @accent && "text-orange-400"]}>{@value}</div>
      <div :if={@sub} class="mt-0.5 text-xs text-zinc-600">{@sub}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  # A count, or a formatted reading like "86.4 MB" / "2.1%" / "-".
  attr :value, :any, required: true

  defp mini(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 px-3 py-2">
      <div class="text-lg font-semibold">{@value}</div>
      <div class="text-xs text-zinc-500">{@label}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :currency, :string, required: true
  attr :rows, :list, required: true

  defp breakdown(assigns) do
    ~H"""
    <div>
      <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{@title}</div>
      <div class="space-y-1 rounded-xl border border-zinc-800 p-2">
        <div :for={r <- @rows} class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-[15px] hover:bg-zinc-800/50">
          <span class="min-w-0 truncate text-zinc-300">{r.key}</span>
          <span class="flex shrink-0 items-center gap-3 text-sm">
            <span class="text-zinc-500">{tokens(r.total)}</span>
            <span class="w-20 text-right font-medium">{money(r.cost, @currency)}</span>
          </span>
        </div>
        <p :if={@rows == []} class="px-2 py-3 text-center text-sm text-zinc-600">{gettext("Nothing yet")}</p>
      </div>
    </div>
    """
  end

  defp bar_pct(_total, []), do: 0

  defp bar_pct(total, days) do
    max = days |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end)
    if max > 0, do: max(round(total / max * 100), 2), else: 0
  end

  # Everything below is counted within the selected company scope (a bare count
  # ignores which company is showing). `in_scope?` treats "all" as everything.
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
  defp scope_label(company), do: company

  @impl true
  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/overview")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}
end
