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
  alias Pepe.Trace

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Traces",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       selected: nil
     )
     |> load_list()}
  end

  defp load_list(socket) do
    scope = socket.assigns.scope
    scopes = if scope == "all", do: Trace.scopes(), else: [scope]

    traces =
      scopes
      |> Enum.flat_map(fn s -> Enum.map(Trace.recent(s, 100), &Map.put(&1, "scope", s)) end)
      |> Enum.sort_by(& &1["at"], :desc)
      |> Enum.take(100)

    assign(socket, traces: traces)
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

        <div class="flex-1 overflow-y-auto p-6">
          <.trace_list :if={!@selected} traces={@traces} />
          <.detail :if={@selected} trace={@selected} />
        </div>
      </main>
    </div>
    """
  end

  attr :traces, :list, required: true

  defp trace_list(assigns) do
    ~H"""
    <div :if={@traces == []} class="rounded-xl border border-dashed border-zinc-800 p-10 text-center text-zinc-500">
      {gettext("No runs recorded yet. Every agent run, from any surface, shows up here.")}
    </div>
    <div :if={@traces != []} class="overflow-x-auto rounded-xl border border-zinc-800">
      <table class="w-full min-w-[720px] text-[15px]">
        <thead class="bg-zinc-900/60 text-left text-sm text-zinc-500">
          <tr>
            <th class="px-3 py-2 font-medium">{gettext("When")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Agent")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Outcome")}</th>
            <th class="px-3 py-2 font-medium">{gettext("Tools")}</th>
            <th class="px-3 py-2 text-right font-medium">{gettext("Took")}</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={t <- @traces} class="border-t border-zinc-800/70 hover:bg-zinc-800/40">
            <td class="whitespace-nowrap px-3 py-2 font-mono text-sm text-zinc-400">{fmt_at(t["at"])}</td>
            <td class="px-3 py-2">
              <span class="text-zinc-200">{t["agent"]}</span>
              <span :if={t["session"]} class="ml-1 text-xs text-zinc-600">{t["session"]}</span>
            </td>
            <td class="px-3 py-2"><.outcome_badge outcome={t["outcome"]} /></td>
            <td class="px-3 py-2 text-sm text-zinc-400">{tools_label(t["tools"])}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right text-sm text-zinc-500">{fmt_ms(t["ms"])}</td>
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

  defp detail(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl space-y-5">
      <div class={card()}>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <div class="text-lg font-semibold">{@trace["agent"]}</div>
            <div class="mt-0.5 text-sm text-zinc-500">
              {fmt_at(@trace["at"])} · {fmt_ms(@trace["ms"])}
              <span :if={@trace["session"]} class="ml-1">· {@trace["session"]}</span>
            </div>
          </div>
          <.outcome_badge outcome={@trace["outcome"]} />
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
    <div class="text-[15px] text-yellow-400">{gettext("Blocked")} · {@ev["name"]}</div>
    """
  end

  defp event(%{ev: %{"t" => "failover"}} = assigns) do
    ~H"""
    <div class="text-sm text-zinc-400">{gettext("Failover")}: {@ev["from"]} → {@ev["to"]}</div>
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

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/traces")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  # --- formatting helpers ------------------------------------------------------------

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

  defp fmt_ms(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)} s"
  defp fmt_ms(ms) when is_integer(ms), do: "#{ms} ms"
  defp fmt_ms(_), do: "–"

  defp fmt_at(at) when is_integer(at) do
    case DateTime.from_unix(at) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "–"
    end
  end

  defp fmt_at(_), do: "–"

  defp event_icon(%{"t" => "tool_call"}), do: "🔧"
  defp event_icon(%{"t" => "tool_result"}), do: "↳"
  defp event_icon(%{"t" => "assistant"}), do: "💬"
  defp event_icon(%{"t" => "tool_denied"}), do: "🚫"
  defp event_icon(%{"t" => "failover"}), do: "⇄"
  defp event_icon(%{"t" => "usage"}), do: "◷"
  defp event_icon(%{"t" => "error"}), do: "⚠"
  defp event_icon(_), do: "·"
end
