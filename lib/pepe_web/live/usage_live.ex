defmodule PepeWeb.UsageLive do
  @moduledoc """
  Usage (billing) section: token consumption metered per company, agent and model,
  aggregated into billing cycles (hour / day / week / month / year). Shows provider
  cost and - when a company has a markup - the amount to bill, side by side. Prices
  come from the layered price book; a button refreshes the live cache.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Pricing

  @granularities %{
    "hour" => :hour,
    "day" => :day,
    "week" => :week,
    "month" => :month,
    "year" => :year
  }

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Usage",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       granularity: "day",
       refreshing: false,
       cache_info: Pricing.cache_info()
     )
     |> load_summary()}
  end

  defp load_summary(socket) do
    gran = Map.get(@granularities, socket.assigns.granularity, :day)
    scope_arg = if socket.assigns.scope == "all", do: :all, else: socket.assigns.scope
    assign(socket, summary: Pepe.Usage.summary(scope_arg, gran, tz: Config.default_timezone()))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="usage" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="📊"
          title={gettext("Usage & billing")}
          desc={gettext("Tokens metered per company, agent and model, by cycle. Cost uses each model's price; the amount to bill adds the company's markup. Prices are editable per model.")}
        >
          <div class="flex items-center gap-2">
            <span class="hidden text-xs text-zinc-500 sm:inline">{price_cache_label(@cache_info)}</span>
            <button phx-click="refresh_prices" disabled={@refreshing} class={btn_ghost()}>
              {if @refreshing, do: gettext("Refreshing..."), else: gettext("Refresh prices")}
            </button>
          </div>
        </.view_header>

        <div class="flex-1 space-y-5 overflow-y-auto p-6">
          <div class="flex flex-wrap items-center gap-1">
            <span class="mr-2 text-sm text-zinc-500">{gettext("Cycle")}</span>
            <button :for={{g, label} <- granularity_options()} phx-click="set_granularity" phx-value-g={g}
              class={[
                "rounded-lg px-3 py-1.5 text-sm transition",
                (@granularity == g && "bg-orange-600 font-medium text-white") ||
                  "border border-zinc-800 bg-zinc-900 text-zinc-300 hover:border-zinc-700"
              ]}>{label}</button>
          </div>

          <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <.stat label={gettext("Total tokens")} value={tokens(@summary.totals.total)} />
            <.stat label={gettext("Calls")} value={Integer.to_string(@summary.totals.count)} />
            <%!-- What we paid. Tokens served by a subscription cost nothing here; the month's
                  flat fee is added on top, once, rather than pretending each token was bought. --%>
            <.stat label={gettext("Provider cost")}
              value={money(@summary.totals.cost + @summary.subscriptions, @summary.currency)}
              sub={
                @summary.subscriptions > 0 &&
                  gettext("incl. %{fee} of subscriptions", fee: money(@summary.subscriptions, @summary.currency))
              } />
            <.stat label={gettext("To bill")} value={money(@summary.totals.billable, @summary.currency)}
              sub={
                @summary.totals.list != @summary.totals.cost &&
                  gettext("at API prices: %{list}", list: money(@summary.totals.list, @summary.currency))
              }
              accent={@summary.totals.billable > @summary.totals.cost} />
          </div>

          <div>
            <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("By cycle")}</div>
            <div class="overflow-x-auto rounded-xl border border-zinc-800">
              <table class="w-full min-w-[640px] text-[15px]">
                <thead class="bg-zinc-900/60 text-left text-sm text-zinc-500">
                  <tr>
                    <th class="px-3 py-2 font-medium">{gettext("Cycle")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Input")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Output")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Total")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Cost")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("To bill")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={b <- Enum.reverse(@summary.buckets)} class="border-t border-zinc-800/70">
                    <td class="px-3 py-2 font-mono text-sm text-zinc-300">{b.key}</td>
                    <td class="px-3 py-2 text-right text-zinc-400">{tokens(b.in)}</td>
                    <td class="px-3 py-2 text-right text-zinc-400">{tokens(b.out)}</td>
                    <td class="px-3 py-2 text-right">{tokens(b.total)}</td>
                    <td class="px-3 py-2 text-right text-zinc-400">{money(b.cost, @summary.currency)}</td>
                    <td class="px-3 py-2 text-right font-medium">{money(b.billable, @summary.currency)}</td>
                  </tr>
                  <tr :if={@summary.buckets == []}>
                    <td colspan="6" class="px-3 py-6 text-center text-[15px] text-zinc-500">{gettext("No usage recorded yet for this scope.")}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="grid gap-5 lg:grid-cols-3">
            <.breakdown :if={@scope == "all"} title={gettext("By company")} currency={@summary.currency}
              rows={Enum.map(@summary.by_company, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={true} />
            <.breakdown title={gettext("By model")} currency={@summary.currency}
              rows={Enum.map(@summary.by_model, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={false} />
            <.breakdown title={gettext("By agent")} currency={@summary.currency}
              rows={Enum.map(@summary.by_agent, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={false} />
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :accent, :boolean, default: false
  # A second line under the figure, or `false`/`nil` for none.
  attr :sub, :any, default: nil

  defp stat(assigns) do
    ~H"""
    <div class={card()}>
      <div class="text-sm text-zinc-500">{@label}</div>
      <div class={["mt-1 text-xl font-semibold", @accent && "text-green-400"]}>{@value}</div>
      <div :if={@sub} class="mt-0.5 text-xs text-zinc-500">{@sub}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :currency, :string, required: true
  attr :rows, :list, required: true
  attr :bill?, :boolean, default: false

  defp breakdown(assigns) do
    ~H"""
    <div>
      <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{@title}</div>
      <div class="space-y-1 rounded-xl border border-zinc-800 p-2">
        <div :for={{name, total, cost, billable} <- @rows} class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-[15px] hover:bg-zinc-800/50">
          <span class="min-w-0 truncate text-zinc-300">{name}</span>
          <span class="flex shrink-0 items-center gap-3 text-sm">
            <span class="text-zinc-500">{tokens(total)}</span>
            <span class="w-20 text-right font-medium">{money((@bill? && billable) || cost, @currency)}</span>
          </span>
        </div>
        <p :if={@rows == []} class="px-2 py-3 text-center text-sm text-zinc-600">{gettext("Nothing yet")}</p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("set_granularity", %{"g" => g}, socket) when is_map_key(@granularities, g) do
    {:noreply, socket |> assign(granularity: g) |> load_summary()}
  end

  def handle_event("refresh_prices", _p, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:prices_refreshed, Pricing.refresh()}) end)
    {:noreply, assign(socket, refreshing: true)}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/usage")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  @impl true
  def handle_info({:prices_refreshed, result}, socket) do
    socket =
      case result do
        {:ok, count} ->
          put_flash(socket, :info, gettext("Refreshed %{count} live prices.", count: count))

        {:error, _} ->
          put_flash(socket, :error, gettext("Couldn't refresh prices. Check the connection."))
      end

    {:noreply, socket |> assign(refreshing: false, cache_info: Pricing.cache_info()) |> load_summary()}
  end
end
