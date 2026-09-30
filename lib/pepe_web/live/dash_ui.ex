defmodule PepeWeb.DashUI do
  @moduledoc """
  Shared UI for the dashboard's per-section LiveViews: the left sidebar (a function
  component) plus the class-string and header helpers every section reuses. Extracted
  so each section can live in its own LiveView while sharing one look and one nav.
  """
  use PepeWeb, :html
  use Gettext, backend: Pepe.Gettext

  alias PepeWeb.DashData

  # Shared Tailwind class strings (functions, since `@name` inside ~H means an assign).
  def fld,
    do:
      "w-full h-[44px] [&:is(textarea)]:h-auto [&:is(textarea)]:min-h-[44px] rounded-[12px] border border-zinc-700 bg-transparent px-4 py-2.5 text-[15px] leading-[22px] text-zinc-100 outline-none transition placeholder:text-zinc-600 hover:border-white/25 focus:border-orange-400/70 focus:ring-1 focus:ring-orange-400/25"

  @doc """
  A compact variant of `fld/0` for a control that has to sit inline with `btn_ghost/0`
  buttons (a header action row, a filter bar) - `fld/0`'s own padding/text size renders
  visibly taller than a `btn_ghost/0` beside it.
  """
  def fld_sm,
    do:
      "h-[44px] [&:is(textarea)]:h-auto [&:is(textarea)]:min-h-[44px] rounded-[12px] border border-zinc-700 bg-transparent px-4 py-2.5 text-[15px] leading-[22px] text-zinc-100 outline-none transition placeholder:text-zinc-600 hover:border-white/25 focus:border-orange-400/70 focus:ring-1 focus:ring-orange-400/25"

  def lbl, do: "mb-1.5 block text-[13.5px] font-medium text-zinc-300"
  def hlp, do: "mt-1.5 text-[13.5px] leading-relaxed text-zinc-500"

  @doc "A plain checkbox styled to match `check_card/1`'s - every hand-rolled checkbox should use this instead of the browser default."
  def checkbox_cls, do: "h-4 w-4 accent-orange-500"

  def card,
    do: "rounded-[14px] border border-zinc-800 bg-zinc-900 p-5 transition hover:border-zinc-700"

  def btn,
    do:
      "inline-flex h-[44px] items-center justify-center gap-2 rounded-[12px] bg-orange-400 px-[18px] text-[14.5px] font-semibold text-on-accent transition hover:bg-orange-300"

  def btn_ghost,
    do:
      "inline-flex h-[44px] items-center justify-center gap-2 rounded-[12px] border border-white/[.12] px-[18px] text-[14.5px] text-zinc-400 transition hover:border-white/25 hover:text-zinc-100"

  @doc "The small monospace caps used for labels above content (\"LAST SEEN\", \"INDICATORS\")."
  def eyebrow, do: "font-mono text-[11px] uppercase tracking-[.18em] text-zinc-600"

  @doc "A table's column heading: monospace caps, quieter than the eyebrow."
  def th, do: "font-mono text-[11px] font-normal uppercase tracking-[.14em] text-[#4e5c68]"

  @doc """
  A status tag in monospace caps (\"LIVE\", \"CONDITION\", \"HUMAN\"): outlined, never filled.
  `kind` is `:ok` (teal), `:warn` (gold), `:danger` (red) or `:muted`.
  """
  def tag(kind) do
    [
      "inline-flex items-center rounded-[4px] border px-1.5 py-[3px] font-mono text-[10.5px] uppercase leading-none tracking-[.12em]",
      case kind do
        :ok -> "border-teal-ink/50 text-teal-ink"
        :warn -> "border-orange-400/50 text-orange-400"
        :danger -> "border-danger-ink/50 text-danger-ink"
        _ -> "border-white/[.14] text-zinc-500"
      end
    ]
  end

  @doc "A pill for a filter, a recent item, a suggestion."
  def chip,
    do:
      "inline-flex items-center gap-2 rounded-full border border-white/[.12] px-3.5 py-2 text-[13.5px] text-zinc-300 transition hover:border-white/25 hover:text-zinc-100"

  defp nav_group_cls,
    do: "px-[13px] pb-[5px] pt-4 font-mono text-[10px] uppercase tracking-[.2em] text-[#4e5c68]"

  @doc """
  The root of a section's page: the flex row that holds the sidebar and the `<main>`.
  `h-dvh` rather than `h-screen` so a mobile browser's collapsing address bar doesn't
  push the bottom of the page (a chat composer, a form's buttons) out of reach.
  """
  def shell_cls, do: "page-ground flex h-dvh overflow-hidden text-zinc-100"

  @doc """
  The scrollable body of a section, under its header. Tighter padding on a phone,
  where 24px of chrome on each side is a sixth of the screen. `min-h-0` lets it
  actually shrink inside a flex column instead of forcing a sibling with its own
  minimum size (a textarea, a form) to collapse to make room for it - see
  `config_live.ex`'s editor. Extra bottom padding so the last element on the page
  never sits flush against the viewport edge. Every section used to inline this
  string by hand and had already drifted (three different variants); callers add
  their own layout/`space-y-*` on top, e.g. `class={[body_cls(), "flex flex-col gap-6"]}`.
  """
  def body_cls, do: "page-body min-h-0 flex-1 overflow-y-auto px-4 pb-10 pt-1 sm:px-8 xl:px-14"

  @doc """
  A dashed-border placeholder for "nothing here yet", standardized from the two
  shapes (`plugins_live.ex`, `integrations_live.ex`) that had already diverged
  before this existed.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class={["rounded-[14px] border border-dashed border-zinc-700 px-6 py-10 text-center text-[14.5px] leading-relaxed text-zinc-500", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil

  slot :item, required: true do
    attr :label, :string, required: true
    attr :mono, :boolean, doc: "set the value in monospace (a URL, a token, a command)"
  end

  @doc """
  The facts under a card's title as aligned rows: a small monospace label on the left, the value in
  a column on the right. Replaces the loose muted lines ("Agent: x", "Token: y") that read as plain
  text. A trailing colon on the label is dropped, so existing "Agent:" strings work as they are.
  """
  def meta_list(assigns) do
    ~H"""
    <dl class={["grid grid-cols-[minmax(4.5rem,max-content)_minmax(0,1fr)] items-baseline gap-x-6 gap-y-2 text-[14px]", @class]}>
      <%= for item <- @item do %>
        <dt class="font-mono text-[11px] uppercase tracking-[.14em] text-zinc-600">{String.trim_trailing(item.label, ":")}</dt>
        <dd class={["min-w-0 break-words text-zinc-300", item[:mono] && "font-mono text-[13px] text-zinc-400"]}>{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  attr :ok, :boolean, required: true
  attr :class, :any, default: nil

  @doc "A result mark: a teal check when it worked, a gold warning triangle when it did not."
  def ok_icon(assigns) do
    ~H"""
    <.icon
      name={(@ok && "hero-check-circle") || "hero-exclamation-triangle"}
      class={["inline size-4 shrink-0", (@ok && "text-teal-ink") || "text-orange-400", @class]}
    />
    """
  end

  attr :label, :string, default: nil, doc: "a short monospace tag in front of the text (\"Warning\")"
  attr :kind, :atom, default: :warn, values: [:warn, :danger, :info]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc """
  A boxed notice: a short monospace label in front of a paragraph, inside an outlined card.
  For the one thing on a page the reader must not skim past (an install that runs code with
  full access, a setting that cannot be undone). Not for ordinary hints, which stay plain text.
  """
  def notice(assigns) do
    ~H"""
    <div
      role="note"
      class={[
        "flex gap-3 rounded-[11px] border px-4 py-3.5 text-[14px] leading-relaxed text-zinc-200",
        @kind == :warn && "border-orange-400/40 bg-orange-400/[.05]",
        @kind == :danger && "border-danger-ink/40 bg-danger-ink/[.05]",
        @kind == :info && "border-white/[.14] bg-white/[.03]",
        @class
      ]}
    >
      <span
        :if={@label}
        class={[
          "mt-[3px] shrink-0 font-mono text-[10.5px] uppercase tracking-[.16em]",
          @kind == :warn && "text-orange-400",
          @kind == :danger && "text-danger-ink",
          @kind == :info && "text-zinc-400"
        ]}
      >
        {@label}
      </span>
      <div class="min-w-0 flex-1 space-y-2.5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :any, default: nil
  # `false` for the default color, or a Tailwind text-color class (e.g. "text-orange-400").
  attr :accent, :any, default: false
  attr :size, :string, default: "text-[22px]"

  @doc """
  A single figure in a card: label, big value, optional sub-line. Was two
  independently-drifted private copies (`overview_live.ex`, `usage_live.ex`) with
  different sizes and accent colors - `size`/`accent` are exposed so each caller
  keeps its own look without forking the markup again.
  """
  def stat(assigns) do
    ~H"""
    <div class={card()}>
      <div class="text-[13.5px] text-zinc-500">{@label}</div>
      <div class={["mt-1.5 font-mono font-normal tracking-tight", @size, @accent || "text-zinc-50"]}>{@value}</div>
      <div :if={@sub} class="mt-1 text-xs text-zinc-600">{@sub}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :kind, :string, default: "bar", values: ~w(bar line)
  attr :labels, :list, required: true
  # Each series: %{name: string, values: [number], tone: "gold" | "slate" | "teal" | "red"}.
  attr :series, :list, required: true
  attr :unit, :string, default: "count", values: ~w(count tokens money percent seconds)
  attr :currency, :string, default: ""
  attr :label, :string, required: true, doc: "what the chart shows, for screen readers"
  # An optional dashed reference line, `%{value: 95, label: "95%"}`.
  attr :goal, :map, default: nil
  attr :class, :string, default: "h-56"

  @doc """
  A chart. The server sends data and a tone per series; how it looks (fonts, hairlines, the
  muted palette) is decided once, in `assets/js/charts.js`. The outer node is what LiveView
  updates, the inner one (`phx-update="ignore"`) is what the chart library draws into.
  """
  def chart(assigns) do
    assigns =
      assign(
        assigns,
        :spec,
        Jason.encode!(%{
          kind: assigns.kind,
          labels: assigns.labels,
          series: assigns.series,
          unit: assigns.unit,
          currency: assigns.currency,
          goal: assigns.goal
        })
      )

    ~H"""
    <div id={@id} phx-hook="Chart" data-spec={@spec} role="img" aria-label={@label} class={["w-full", @class]}>
      <div id={@id <> "-canvas"} phx-update="ignore" class="size-full"></div>
    </div>
    """
  end

  attr :tabs, :list, required: true, doc: "a list of {id, label}"
  attr :active, :string, required: true
  attr :event, :string, required: true, doc: "the phx-click event, sent with phx-value-tab"
  slot :actions, doc: "controls at the right end of the bar"

  @doc """
  A row of page tabs. Every tab has the same font weight and the bar keeps its height whatever
  is in `:actions`, so switching tabs never moves the content under it.
  """
  def tabs(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3 border-b border-zinc-800">
      <div role="tablist" class="-mb-px flex gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <button
          :for={{id, label} <- @tabs}
          type="button"
          role="tab"
          phx-click={@event}
          phx-value-tab={id}
          aria-selected={to_string(@active == id)}
          class={[
            "shrink-0 border-b-2 px-4 py-2.5 text-base font-medium transition focus-visible:outline-offset-[-3px]",
            (@active == id && "border-orange-400 text-orange-300") || "border-transparent text-zinc-400 hover:text-zinc-100"
          ]}
        >
          {label}
        </button>
      </div>
      {render_slot(@actions)}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  # Percent move against the previous period, or nil when there was nothing to compare with.
  attr :change, :any, default: nil
  # `:bad_up` for a figure where going up is a problem (errors, reply time), `:good_up` where it is
  # the good news (success rate, money saved); `:neutral` for the rest, where up is neither
  # (spend, tokens, runs depend on what you were hoping for).
  attr :tone, :atom, default: :neutral, values: [:neutral, :bad_up, :good_up]
  # What follows the number in the change: "%" for a relative move, "pts" for a rate's.
  attr :delta_unit, :string, default: "%"
  attr :versus, :string, required: true, doc: "e.g. \"last week\""
  attr :before, :string, default: nil, doc: "the previous period's value, formatted"

  @doc "A figure with how much it moved since the previous period."
  def compare_tile(assigns) do
    ~H"""
    <div class={card()}>
      <div class="text-[13.5px] text-zinc-500">{@label}</div>
      <div class="mt-1.5 font-mono text-[22px] font-normal tracking-tight text-zinc-50">{@value}</div>
      <div class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px]">
        <span :if={is_nil(@change)} class="text-zinc-600">{gettext("Nothing to compare with yet")}</span>
        <span :if={@change} class={["inline-flex items-center gap-0.5 font-medium", delta_cls(@change, @tone)]}>
          <.icon name={if @change > 0, do: "hero-arrow-up-mini", else: "hero-arrow-down-mini"} class={["size-4", @change == 0 && "hidden"]} />{delta_text(@change)}{@delta_unit}
        </span>
        <span :if={@change} class="text-zinc-600">{gettext("vs %{period}", period: @versus)}<span :if={@before}>{", "}{@before}</span></span>
      </div>
    </div>
    """
  end

  defp delta_cls(change, _tone) when change == 0, do: "text-zinc-500"
  defp delta_cls(change, :bad_up) when change > 0, do: "text-danger-ink"
  defp delta_cls(_change, :bad_up), do: "text-teal-ink"
  defp delta_cls(change, :good_up) when change > 0, do: "text-teal-ink"
  defp delta_cls(_change, :good_up), do: "text-danger-ink"
  defp delta_cls(_change, :neutral), do: "text-zinc-300"

  defp delta_text(change) when change == 0, do: "0"

  defp delta_text(change) do
    value = abs(change)
    "#{if value == trunc(value), do: trunc(value), else: value}"
  end

  attr :title, :string, required: true
  attr :currency, :string, required: true
  # Each row: %{key: string, total: integer (token count), cost: number}. A caller that
  # needs to choose between two cost figures (billable vs. actual, `usage_live.ex`)
  # resolves that itself and passes the already-chosen `cost` in - this component only
  # ever renders one number per row.
  attr :rows, :list, required: true

  @doc """
  A titled list of "name → tokens, cost" rows. Was two independently-drifted private
  copies (`overview_live.ex`, `usage_live.ex`); the billable-vs-cost choice `usage_live`
  needed stays in that screen's own data prep, not in this shared component.
  """
  def breakdown(assigns) do
    ~H"""
    <div>
      <div class="mb-2 font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{@title}</div>
      <div class="space-y-1 rounded-xl border border-zinc-800 p-2">
        <div :for={r <- @rows} class="flex items-center justify-between gap-2 rounded px-2 py-1.5 text-base">
          <span class="min-w-0 truncate text-zinc-300">{r.key}</span>
          <span class="flex shrink-0 items-center gap-3 text-sm">
            <span class="text-zinc-500">{DashData.tokens(r.total)}</span>
            <span class="w-20 text-right font-medium">{DashData.money(r.cost, @currency)}</span>
          </span>
        </div>
        <p :if={@rows == []} class="px-2 py-3 text-center text-sm text-zinc-600">{gettext("Nothing yet")}</p>
      </div>
    </div>
    """
  end

  # The id of the checkbox that drives the mobile drawer. The sidebar renders it; every
  # `<label for=...>` pointing at it (the hamburger, the backdrop) toggles the drawer with
  # no JavaScript and no LiveView state, so a section doesn't need an event handler to have
  # a working menu.
  defp nav_toggle_id, do: "pepe-nav-toggle"

  # A button that copies `@value` to the clipboard, swapping to a checkmark for 1.5s.
  attr :value, :string, required: true
  attr :id, :string, required: true
  attr :class, :any, default: nil

  def copy_button(assigns) do
    ~H"""
    <button type="button" id={@id} phx-hook=".CopyToClipboard" data-copy={@value} class={[btn_ghost(), @class]} title={gettext("Copy")}>
      <.icon name="hero-clipboard-document" class="copy-icon size-4" />
      <.icon name="hero-check" class="copied-icon hidden size-4" />
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          const copyIcon = this.el.querySelector(".copy-icon")
          const copiedIcon = this.el.querySelector(".copied-icon")

          this.el.addEventListener("click", () => {
            navigator.clipboard.writeText(this.el.dataset.copy)
            copyIcon.classList.add("hidden")
            copiedIcon.classList.remove("hidden")
            clearTimeout(this._t)
            this._t = setTimeout(() => {
              copiedIcon.classList.add("hidden")
              copyIcon.classList.remove("hidden")
            }, 1500)
          })
        },
        destroyed() {
          clearTimeout(this._t)
        }
      }
    </script>
    """
  end

  attr :title, :string, required: true
  # Opt-in: a form with many sections (the agent editor) can pass collapsible so each one is
  # a native <details> the operator opens on demand, instead of one long undifferentiated
  # scroll. Other callers (models, config, connections) are untouched by this - false keeps
  # the plain, always-open <div> every existing caller already renders.
  attr :collapsible, :boolean, default: false
  attr :open, :boolean, default: false
  # A stable id for a collapsible section, so the hook below can tell "this is the same
  # <details> as last render" across a phx-change patch. Required only when collapsible;
  # a plain, non-collapsible section has no open/closed state to preserve.
  attr :id, :string, default: nil
  slot :inner_block, required: true

  @doc """
  A titled group of related fields inside a form - groups a long flat form into
  scannable chunks (e.g. "Connection", "Reliability", "Billing") instead of one
  undifferentiated list of inputs.
  """
  def form_section(assigns) do
    ~H"""
    <div :if={!@collapsible} class="space-y-6 rounded-xl border border-zinc-800/80 bg-zinc-900/30 p-4 sm:p-6">
      <div class="border-b border-zinc-800 pb-3 text-base font-medium text-zinc-100">
        {@title}
      </div>
      {render_slot(@inner_block)}
    </div>
    <%!-- `open` only sets the INITIAL state: @open never changes after mount, but every other
          field in this same form re-renders this section on every phx-change (checking a box
          elsewhere in the form included), and without help LiveView's patch would reassert
          `open={@open}` and slam shut whatever the operator had opened by hand. The hook below
          remembers the section's live open/closed state across patches instead. --%>
    <details :if={@collapsible} open={@open} id={@id} phx-hook=".KeepOpen" class="group rounded-xl border border-zinc-800/80 bg-zinc-900/30">
      <summary class="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-base font-medium text-zinc-100 marker:hidden [&::-webkit-details-marker]:hidden sm:px-6 sm:py-4">
        {@title}
        <.icon name="hero-chevron-down" class="size-4 shrink-0 text-zinc-500 transition group-open:rotate-180" />
      </summary>
      <div class="space-y-6 border-t border-zinc-800 p-4 sm:p-6">
        {render_slot(@inner_block)}
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".KeepOpen">
      export default {
        mounted() {
          this.userOpen = this.el.open
          this.el.addEventListener("toggle", () => { this.userOpen = this.el.open })
        },
        updated() {
          this.el.open = this.userOpen
        }
      }
    </script>
    """
  end

  attr :title, :string, required: true
  attr :class, :string, default: nil

  @doc """
  The slim bar at the top of every page: the nav drawer button below `md` and the breadcrumb.
  `view_header/1` starts with it; the chat, which has no title block, uses it alone.
  """
  def page_topbar(assigns) do
    ~H"""
    <div class={["flex min-h-14 shrink-0 items-center gap-4 px-4 py-2 sm:px-8 xl:px-14", @class]}>
      <.nav_toggle class="" />
      <nav aria-label="Breadcrumb" class="flex min-w-0 items-center gap-2.5">
        <span class="text-[14.5px] font-semibold tracking-[.01em] text-zinc-100">Pepe</span>
        <span class="text-xs text-[#4e5c68]">/</span>
        <span class="truncate text-[13.5px] text-zinc-400">{@title}</span>
      </nav>
    </div>
    """
  end

  # `icon` is kept so existing callers still compile; the page no longer draws an emoji.
  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :desc, :string, required: true
  # The sidebar key of the page (the same one it passes to `sidebar/1`), so the header can name
  # the nav group above the title.
  attr :active, :string, default: nil
  slot :inner_block

  @doc """
  A page's header, in two parts: a slim top bar (the breadcrumb and the page's actions) and
  the title block (a small monospace group label, the title, one plain sentence about the
  page). Below `md` the hamburger that opens the nav drawer sits left of the breadcrumb.
  """
  def view_header(assigns) do
    assigns = assign(assigns, :group, nav_group(assigns.active))

    ~H"""
    <header class="shrink-0">
      <.page_topbar title={@title} />
      <%!-- The title block and its actions share one column, capped like the page body below it,
            so on a wide screen the page's main button stays next to its title instead of drifting
            to the far edge of the window. --%>
      <div class="px-4 pb-8 pt-4 sm:px-8 xl:px-14">
        <div class="page-column flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
          <div class="min-w-0">
            <div :if={@group} class="font-mono text-[12px] uppercase tracking-[.16em] text-orange-400">{@group}</div>
            <h1 class={["break-words text-[2rem] font-light leading-[1.22] tracking-[-0.02em] text-zinc-50 sm:text-[2.375rem]", @group && "mt-3"]}>{@title}</h1>
            <p class="mt-3 max-w-[560px] text-[15.5px] leading-[1.6] text-zinc-500">{@desc}</p>
          </div>
          <div :if={@inner_block != []} class="flex shrink-0 flex-wrap items-center gap-2 pb-1">{render_slot(@inner_block)}</div>
        </div>
      </div>
    </header>
    """
  end

  # The sidebar's sections: a label (nil for the unlabelled top block) and its pages as
  # {path key, icon, label}. One list drives both the sidebar and the header's group label.
  defp nav_sections do
    [
      {nil,
       [
         {"overview", "hero-home", gettext("Overview")},
         {"chat", "hero-chat-bubble-left", gettext("Chat")}
       ]},
      {gettext("Build"),
       [
         {"projects", "hero-building-office", gettext("Projects")},
         {"agents", "hero-puzzle-piece", gettext("Agents")},
         {"models", "hero-cpu-chip", gettext("Models")},
         {"mcp", "hero-wrench-screwdriver", "MCP"},
         {"databases", "hero-circle-stack", gettext("Databases")},
         {"skills", "hero-book-open", gettext("Skills")},
         {"plugins", "hero-squares-plus", gettext("Plugins")}
       ]},
      {gettext("Automation"),
       [
         {"cron", "hero-clock", gettext("Scheduled")},
         {"board", "hero-view-columns", gettext("Board")},
         {"watches", "hero-eye", gettext("Watches")},
         {"commitments", "hero-hand-raised", gettext("Commitments")},
         {"bots", "hero-signal", gettext("Channels")},
         {"integrations", "hero-link", gettext("Integrations")}
       ]},
      {gettext("Insight"),
       [
         {"learn", "hero-sparkles", gettext("Learning")},
         {"usage", "hero-chart-bar", gettext("Usage & billing")},
         {"traces", "hero-queue-list", gettext("Traces")}
       ]},
      {gettext("System"),
       [
         {"hooks", "hero-shield-check", gettext("Privacy")},
         {"tokens", "hero-key", gettext("API tokens")},
         {"config", "hero-cog-6-tooth", gettext("Configuration")}
       ]}
    ]
  end

  # The label of the sidebar group a page belongs to, for the header's small caps line.
  defp nav_group(nil), do: nil
  defp nav_group("overview"), do: gettext("Home")

  defp nav_group(active) do
    Enum.find_value(nav_sections(), fn {group, items} ->
      group && Enum.any?(items, fn {key, _icon, _label} -> key == active end) && group
    end)
  end

  @doc """
  The hamburger that opens the nav drawer. A `<label>`, not a button: it flips the
  sidebar's checkbox, so it works on any section without that section handling an event.
  Hidden from `md` up, where the sidebar is always on screen.
  """
  attr :class, :any, default: "mt-0.5"

  def nav_toggle(assigns) do
    ~H"""
    <label
      for={nav_toggle_id()}
      aria-label={gettext("Open the menu")}
      class={[
        "inline-flex size-9 shrink-0 cursor-pointer items-center justify-center rounded-lg border border-zinc-800 bg-zinc-900 text-zinc-300 transition hover:border-zinc-700 hover:text-white md:hidden",
        @class
      ]}
    >
      <.icon name="hero-bars-3" class="size-5" />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, default: false
  attr :hint, :string, default: ""

  @doc "A roomy checkbox toggle: a bigger box, the identifier, and a one-line hint below."
  def check_card(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start gap-2.5 rounded-lg border border-zinc-800 bg-zinc-900/40 p-2.5 transition hover:border-zinc-700">
      <input type="checkbox" name={@name} value={@value} checked={@checked}
        class="mt-0.5 h-4 w-4 shrink-0 accent-orange-500" />
      <div class="min-w-0">
        <div class="font-mono text-sm text-zinc-200">{@value}</div>
        <div :if={@hint != ""} class="mt-0.5 text-xs leading-snug text-zinc-500">{@hint}</div>
      </div>
    </label>
    """
  end

  attr :active, :string, required: true
  attr :scope, :string, default: "all"
  attr :projects, :list, default: []
  attr :new_project, :boolean, default: false

  @doc """
  The left navigation sidebar, shared by every section. `active` is the current
  section's path key (e.g. "agents") for highlighting. The workspace scope selector
  drives `set_scope`/`project_add`/`toggle_new_project`, which each LiveView handles.

  Below `md` it is an off-canvas drawer: a hidden checkbox (`peer`) that every
  `<.nav_toggle />` and the backdrop toggle, sliding the panel in over the content.
  From `md` up the checkbox stops mattering and it is the plain static column again.
  """
  def sidebar(assigns) do
    ~H"""
    <%!-- `md:hidden` (not just `sr-only`) so on a wide screen, where the drawer doesn't
          exist, this control is out of the tab order and out of the a11y tree entirely.
          `display: none` on a peer doesn't affect `peer-checked:` on its siblings. --%>
    <input
      type="checkbox"
      id={nav_toggle_id()}
      class="peer sr-only md:hidden"
      aria-label={gettext("Navigation menu")}
      phx-hook=".NavDrawer"
    />
    <%!-- The backdrop closes the drawer when tapped. `md:hidden` beats the peer-driven
          opacity because it sets `display`, so it can't linger on a wide screen. --%>
    <label
      for={nav_toggle_id()}
      aria-hidden="true"
      class="pointer-events-none fixed inset-0 z-30 bg-black/60 opacity-0 transition-opacity duration-200 peer-checked:pointer-events-auto peer-checked:opacity-100 md:hidden"
    >
    </label>
    <aside class="fixed inset-y-0 left-0 z-40 flex w-[17rem] max-w-[85vw] -translate-x-full flex-col border-r border-white/[.06] bg-rail transition-transform duration-200 ease-out peer-checked:translate-x-0 md:static md:z-auto md:w-[248px] md:max-w-none md:shrink-0 md:translate-x-0">
      <.link navigate={~p"/"} class="flex items-center gap-3 px-6 pb-4 pt-6">
        <svg width="28" height="38" viewBox="16 8 32 44" class="mt-1 shrink-0" role="img" aria-label="Pepe">
          <g stroke="#a1a1aa" stroke-width="3" stroke-linecap="round" fill="none">
            <path d="M26 22 L 21 13" />
            <path d="M38 22 L 43 13" />
          </g>
          <circle cx="20.5" cy="12" r="3.2" fill="#e2231a" />
          <circle cx="43.5" cy="12" r="3.2" fill="#f5b301" />
          <rect x="18" y="22" width="28" height="27" rx="9" fill="none" stroke="#e4e4e7" stroke-width="3.4" />
        </svg>
        <%!-- The wordmark keeps the system font it always had; the dashboard's own font is for the page. --%>
        <div class="leading-tight [font-family:ui-sans-serif,system-ui,-apple-system,'Segoe_UI',sans-serif]">
          <div class="text-lg font-semibold text-zinc-100">Pepe</div>
          <div class="text-xs text-zinc-500">{gettext("agent runtime")}</div>
        </div>
      </.link>

      <div class="mx-4 mb-3">
        <div class={[eyebrow(), "mb-1.5 px-1"]}>{gettext("Project")}</div>
        <div class="flex items-center gap-1.5">
          <form id="scope-form" phx-change="set_scope" class="min-w-0 flex-1" title={gettext("Pick a project to see and configure only its agents, models and automations.")}>
            <select
              name="scope"
              aria-label={gettext("Project")}
              class="h-[42px] w-full rounded-[12px] border border-transparent bg-white/[.05] px-3.5 text-[14px] font-medium text-zinc-100 outline-none transition hover:bg-white/[.08] focus:border-orange-400/50"
            >
              <option value="all" selected={@scope == "all"}>{gettext("All projects")}</option>
              <option value="root" selected={@scope == "root"}>{gettext("Principal")}</option>
              <option :for={c <- @projects} value={c} selected={@scope == c}>{c}</option>
            </select>
          </form>
          <button
            type="button"
            phx-click="toggle_new_project"
            title={(@new_project && gettext("Cancel")) || gettext("+ New project")}
            aria-label={(@new_project && gettext("Cancel")) || gettext("+ New project")}
            class="grid size-[42px] shrink-0 place-items-center rounded-[12px] text-zinc-500 transition hover:bg-white/[.06] hover:text-zinc-100"
          >
            <.icon name={(@new_project && "hero-x-mark") || "hero-plus"} class="size-[18px]" />
          </button>
        </div>
        <form :if={@new_project} phx-submit="project_add" class="mt-2 flex items-center gap-1.5">
          <input
            name="name"
            placeholder={gettext("project name")}
            required
            autocomplete="off"
            phx-mounted={JS.focus()}
            class={[fld_sm(), "min-w-0 flex-1"]}
          />
          <button
            type="submit"
            title={gettext("Add")}
            aria-label={gettext("Add")}
            class="grid size-[42px] shrink-0 place-items-center rounded-[12px] bg-orange-400 text-on-accent transition hover:bg-orange-300"
          >
            <.icon name="hero-check" class="size-[18px]" />
          </button>
        </form>
      </div>

      <nav id="pepe-nav" phx-hook=".NavScroll" aria-label={gettext("Navigation menu")} class="flex-1 overflow-y-auto px-4 pb-4">
        <div :for={{group, items} <- nav_sections()}>
          <div :if={group} class={nav_group_cls()}>{group}</div>
          <div class="space-y-0.5">
            <.nav_item :for={{key, icon, label} <- items} active={@active} scope={@scope} to={key} icon={icon} label={label} />
          </div>
        </div>
      </nav>
      <div class="border-t border-white/[.06] px-6 py-3.5 font-mono text-[11.5px] tracking-[.04em] text-zinc-600">
        <.link :if={Pepe.Config.dashboard_auth_required?()} href="/logout" method="delete" class="mb-1 block text-zinc-500 transition hover:text-zinc-200">
          {gettext("Sign out")}
        </.link>
        {gettext("Pepe")} v{Pepe.Update.current()}
      </div>
    </aside>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".NavScroll">
      export default {
        mounted() {
          // Every menu item is a different LiveView, so a click rebuilds the whole page,
          // sidebar included, and the menu would snap back to the top. Keep where it was
          // scrolled to across those navigations, and make sure the current page's item is
          // on screen (a deep link, or a first visit, lands with it out of view).
          const key = "pepe:nav-scroll"
          try {
            const saved = sessionStorage.getItem(key)
            if (saved !== null) this.el.scrollTop = parseInt(saved, 10) || 0
          } catch (_) {}

          const active = this.el.querySelector('[aria-current="page"]')
          if (active) {
            const box = this.el.getBoundingClientRect()
            const item = active.getBoundingClientRect()
            if (item.top < box.top || item.bottom > box.bottom) active.scrollIntoView({ block: "nearest" })
          }

          this.onScroll = () => {
            try { sessionStorage.setItem(key, String(this.el.scrollTop)) } catch (_) {}
          }
          this.el.addEventListener("scroll", this.onScroll, { passive: true })
        },
        destroyed() {
          this.el.removeEventListener("scroll", this.onScroll)
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NavDrawer">
      export default {
        mounted() {
          // The drawer is CSS state, so nothing else would ever close it. Close it when a
          // nav link takes us somewhere (only a real redirect or patch - a form change also
          // fires the loading event, and the project selector lives inside the drawer),
          // and on Escape.
          this.onNav = (e) => {
            if (["redirect", "patch"].includes(e.detail && e.detail.kind)) this.el.checked = false
          }
          this.onKey = (e) => { if (e.key === "Escape") this.el.checked = false }
          window.addEventListener("phx:page-loading-start", this.onNav)
          window.addEventListener("keydown", this.onKey)
        },
        destroyed() {
          window.removeEventListener("phx:page-loading-start", this.onNav)
          window.removeEventListener("keydown", this.onKey)
        }
      }
    </script>
    """
  end

  attr :active, :string, required: true
  attr :scope, :string, default: "all"
  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={nav_href(@to, @scope)}
      aria-current={@active == @to && "page"}
      class={[
        "flex h-[38px] w-full items-center rounded-[11px] pr-2.5 text-left text-[14px] font-medium transition",
        (@active == @to && "bg-orange-400/[.13] text-orange-400") ||
          "text-zinc-500 hover:bg-white/[.04] hover:text-zinc-200"
      ]}
    >
      <span class="grid size-[38px] shrink-0 place-items-center"><.icon name={@icon} class="size-[18px]" /></span>
      <span class="truncate">{@label}</span>
    </.link>
    """
  end

  # Keep the selected project (scope) across navigation by carrying it in the URL.
  defp nav_href(to, scope) when scope in [nil, "", "all"], do: "/#{to}"
  defp nav_href(to, scope), do: "/#{to}?scope=#{scope}"
end
