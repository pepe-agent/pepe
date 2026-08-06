defmodule PepeWeb.UsageLive do
  @moduledoc """
  Usage (billing) section: token consumption metered per project, agent and model,
  aggregated into billing cycles (hour / day / week / month / year). Shows provider
  cost and - when a project has a markup - the amount to bill, side by side. Prices
  come from the layered price book; a button refreshes the live cache.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Pricing
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs

  @runs_shown 25

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
       projects: Config.project_slugs(),
       new_project: false,
       granularity: "day",
       refreshing: false,
       cache_info: Pricing.cache_info()
     )
     |> assign(open_run: nil)
     |> load_summary()
     |> load_runs()}
  end

  defp load_summary(socket) do
    gran = Map.get(@granularities, socket.assigns.granularity, :day)
    assign(socket, summary: Pepe.Usage.summary(scope_arg(socket), gran, tz: Config.default_timezone()))
  end

  # The last messages, each with the several model calls it actually took. A cycle report
  # counts calls and so can never show this: what makes one message expensive is its number
  # of iterations, because each one re-sends a context the previous tool result just grew.
  defp load_runs(socket) do
    scope = scope_arg(socket)
    runs = Runs.list(scope, limit: @runs_shown)

    assign(socket, runs: runs, run_money: run_money(scope, runs))
  end

  defp run_money(scope, runs) do
    scope
    |> Log.entries_for_runs(Enum.map(runs, & &1["id"]))
    |> Pepe.Usage.price_entries()
    |> Enum.group_by(& &1["run_id"])
    |> Map.new(fn {run_id, entries} -> {run_id, sum_priced(entries)} end)
  end

  defp sum_priced(entries) do
    Enum.reduce(entries, %{calls: 0, total: 0, cost: 0.0, billable: 0.0}, fn e, acc ->
      %{
        calls: acc.calls + 1,
        total: acc.total + e["in"] + e["out"],
        cost: acc.cost + e["cost"],
        billable: acc.billable + e["billable"]
      }
    end)
  end

  defp scope_arg(socket), do: if(socket.assigns.scope == "all", do: :all, else: socket.assigns.scope)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="usage" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="📊"
          title={gettext("Usage & billing")}
          desc={gettext("Tokens metered per project, agent and model, by cycle. Cost uses each model's price; the amount to bill adds the project's markup. Prices are editable per model.")}
        >
          <div class="flex items-center gap-2">
            <span class="hidden text-xs text-zinc-500 sm:inline">{price_cache_label(@cache_info)}</span>
            <button phx-click="refresh_prices" disabled={@refreshing} class={btn_ghost()}>
              {if @refreshing, do: gettext("Refreshing..."), else: gettext("Refresh prices")}
            </button>
          </div>
        </.view_header>

        <div class="flex-1 space-y-5 overflow-y-auto p-4 sm:p-6">
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
            <%!-- The empty state is its own block, not a `colspan` row: inside the table it
                  would inherit the 640px min width and scroll out of sight on a phone. --%>
            <div :if={@summary.buckets == []} class="rounded-xl border border-zinc-800 px-3 py-6 text-center text-[15px] text-zinc-500">
              {gettext("No usage recorded yet for this scope.")}
            </div>
            <div :if={@summary.buckets != []} class="overflow-x-auto rounded-xl border border-zinc-800">
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
                </tbody>
              </table>
            </div>
          </div>

          <div class="grid gap-5 lg:grid-cols-3">
            <.breakdown :if={@scope == "all"} title={gettext("By project")} currency={@summary.currency}
              rows={Enum.map(@summary.by_project, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={true} />
            <.breakdown title={gettext("By model")} currency={@summary.currency}
              rows={Enum.map(@summary.by_model, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={false} />
            <.breakdown title={gettext("By agent")} currency={@summary.currency}
              rows={Enum.map(@summary.by_agent, &{&1.key, &1.total, &1.cost, &1.billable})} bill?={false} />
          </div>

          <div>
            <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("By message")}</div>
            <p class="mb-2 text-sm text-zinc-500">
              {gettext("One line per incoming message. A message often takes several model calls: answer, run a tool, read the result, answer again. Calls drive the cost, not tools: every call re-sends the whole conversation, and each tool result makes it longer.")}
            </p>

            <div :if={@runs == []} class="rounded-xl border border-zinc-800 px-3 py-6 text-center text-[15px] text-zinc-500">
              {gettext("No messages recorded yet for this scope.")}
            </div>

            <div :if={@runs != []} class="overflow-x-auto rounded-xl border border-zinc-800">
              <table class="w-full min-w-[720px] text-[15px]">
                <thead class="bg-zinc-900/60 text-left text-sm text-zinc-500">
                  <tr>
                    <th class="px-3 py-2 font-medium">{gettext("When")}</th>
                    <th class="px-3 py-2 font-medium">{gettext("Agent")}</th>
                    <th class="px-3 py-2 font-medium">{gettext("Came from")}</th>
                    <th class="px-3 py-2 font-medium">{gettext("Tools")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Calls")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("Took")}</th>
                    <th class="px-3 py-2 text-right font-medium">{gettext("To bill")}</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for run <- @runs do %>
                    <tr
                      phx-click="toggle_run"
                      phx-value-id={run["id"]}
                      class="cursor-pointer border-t border-zinc-800/70 hover:bg-zinc-800/40"
                    >
                      <td class="px-3 py-2 font-mono text-sm text-zinc-400">{run_time(run["at"])}</td>
                      <td class="px-3 py-2 truncate text-zinc-300">{run["agent"]}</td>
                      <td class="px-3 py-2 text-sm text-zinc-500">{run["source"] || "-"}</td>
                      <td class="px-3 py-2 text-sm text-zinc-400">
                        {(run["tools"] == [] && gettext("none")) || Enum.join(Enum.uniq(run["tools"]), ", ")}
                      </td>
                      <td class="px-3 py-2 text-right">{money_of(@run_money, run["id"], :calls)}</td>
                      <td class="px-3 py-2 text-right text-sm text-zinc-500">{duration(run["ms"])}</td>
                      <td class="px-3 py-2 text-right font-medium">
                        {money(money_of(@run_money, run["id"], :billable), @summary.currency)}
                      </td>
                    </tr>
                    <tr :if={@open_run && @open_run["id"] == run["id"]} class="border-t border-zinc-800/70 bg-zinc-950/60">
                      <td colspan="7" class="px-3 py-3">
                        <div class="mb-2 text-sm text-zinc-500">
                          {gettext("Every model call this message took, in order")}
                        </div>
                        <div :for={call <- @open_run["calls"]} class="flex items-center justify-between gap-3 py-1 text-sm">
                          <span class="min-w-0 truncate font-mono text-zinc-400">{call["model"]}</span>
                          <span class="flex shrink-0 items-center gap-4">
                            <span class="text-zinc-500">{tokens(call["in"] + call["out"])} tok</span>
                            <span :if={(call["cached"] || 0) > 0} class="text-zinc-600">
                              {gettext("%{n} cached", n: tokens(call["cached"]))}
                            </span>
                            <span class="w-24 text-right">{money(call["billable"], @summary.currency)}</span>
                          </span>
                        </div>
                        <div :if={@open_run["calls"] == []} class="py-1 text-sm text-zinc-600">
                          {gettext("No metered call recorded for this message.")}
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
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

  defp money_of(run_money, id, field) do
    case Map.get(run_money, id) do
      nil -> if field == :calls, do: 0, else: 0.0
      totals -> Map.fetch!(totals, field)
    end
  end

  defp run_time(at), do: at |> DateTime.from_unix!() |> Calendar.strftime("%d/%m %H:%M:%S")

  defp duration(nil), do: "-"
  defp duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @impl true
  def handle_event("set_granularity", %{"g" => g}, socket) when is_map_key(@granularities, g) do
    {:noreply, socket |> assign(granularity: g) |> load_summary()}
  end

  # The breakdown is only loaded when a row is opened: a page of runs would otherwise read
  # and price every call behind every one of them just to render the collapsed rows.
  def handle_event("toggle_run", %{"id" => id}, socket) do
    if socket.assigns.open_run && socket.assigns.open_run["id"] == id do
      {:noreply, assign(socket, open_run: nil)}
    else
      {:noreply, assign(socket, open_run: %{"id" => id, "calls" => run_calls(socket, id)})}
    end
  end

  def handle_event("refresh_prices", _p, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:prices_refreshed, Pricing.refresh()}) end)
    {:noreply, assign(socket, refreshing: true)}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/usage")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp run_calls(socket, id) do
    socket |> scope_arg() |> Log.entries_for_run(id) |> Pepe.Usage.price_entries()
  end

  @impl true
  def handle_info({:prices_refreshed, result}, socket) do
    socket =
      case result do
        {:ok, count} ->
          put_flash(socket, :info, gettext("Refreshed %{count} live prices.", count: count))

        {:error, _} ->
          put_flash(socket, :error, gettext("Couldn't refresh prices. Check the connection."))
      end

    # Runs reload too: their money is priced from the same cache the refresh just replaced,
    # so leaving them alone would show new prices above and old prices below.
    {:noreply,
     socket
     |> assign(refreshing: false, cache_info: Pricing.cache_info())
     |> load_summary()
     |> load_runs()}
  end
end
