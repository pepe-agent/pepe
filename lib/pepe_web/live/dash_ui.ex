defmodule PepeWeb.DashUI do
  @moduledoc """
  Shared UI for the dashboard's per-section LiveViews: the left sidebar (a function
  component) plus the class-string and header helpers every section reuses. Extracted
  so each section can live in its own LiveView while sharing one look and one nav.
  """
  use PepeWeb, :html
  use Gettext, backend: Pepe.Gettext

  # Shared Tailwind class strings (functions, since `@name` inside ~H means an assign).
  def fld,
    do:
      "w-full rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 outline-none transition placeholder:text-zinc-600 focus:border-orange-500 focus:ring-1 focus:ring-orange-500"

  def lbl, do: "mb-1 block text-xs font-medium text-zinc-300"
  def hlp, do: "mt-1 text-xs leading-relaxed text-zinc-500"

  def card,
    do: "rounded-xl border border-zinc-800 bg-zinc-900/50 p-4 transition hover:border-zinc-700"

  def btn,
    do:
      "rounded-lg bg-orange-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-orange-500"

  def btn_ghost,
    do:
      "rounded-lg border border-zinc-800 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-300 transition hover:border-zinc-700 hover:text-white"

  defp nav_group_cls,
    do: "px-3 pb-1 text-[11px] font-semibold uppercase tracking-wider text-zinc-600"

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  slot :inner_block

  @doc "A consistent header for a section: icon + title, a one-line description, and optional actions."
  def view_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4 border-b border-zinc-800 px-6 py-4">
      <div class="min-w-0">
        <div class="flex items-center gap-2 font-medium">
          <span>{@icon}</span> <span class="truncate">{@title}</span>
        </div>
        <div class="mt-0.5 text-xs leading-relaxed text-zinc-500">{@desc}</div>
      </div>
      <div class="flex shrink-0 items-center gap-2">{render_slot(@inner_block)}</div>
    </header>
    """
  end

  attr :active, :string, required: true
  attr :scope, :string, default: "all"
  attr :companies, :list, default: []
  attr :new_company, :boolean, default: false

  @doc """
  The left navigation sidebar, shared by every section. `active` is the current
  section's path key (e.g. "agents") for highlighting. The workspace scope selector
  drives `set_scope`/`company_add`/`toggle_new_company`, which each LiveView handles.
  """
  def sidebar(assigns) do
    ~H"""
    <aside class="flex w-60 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/40">
      <.link navigate={~p"/"} class="flex items-center gap-2 border-b border-zinc-800 px-5 py-4">
        <svg width="25" height="34" viewBox="16 8 32 44" class="mt-1 shrink-0" role="img" aria-label="Pepe">
          <g stroke="#a1a1aa" stroke-width="3" stroke-linecap="round" fill="none">
            <path d="M26 24 L 21 13" />
            <path d="M38 24 L 43 13" />
          </g>
          <circle cx="20.5" cy="12" r="3.2" fill="#e2231a" />
          <circle cx="43.5" cy="12" r="3.2" fill="#f5b301" />
          <rect x="18" y="22" width="28" height="27" rx="9" fill="none" stroke="#e4e4e7" stroke-width="3.4" />
        </svg>
        <div class="leading-tight">
          <div class="font-semibold">Pepe</div>
          <div class="text-[11px] text-zinc-500">agent runtime</div>
        </div>
      </.link>

      <div class="border-b border-zinc-800 px-3 py-3">
        <label class="mb-1 block px-1 text-[11px] font-semibold uppercase tracking-wider text-zinc-600">
          {gettext("Workspace")}
        </label>
        <form phx-change="set_scope">
          <select name="scope" class={fld()}>
            <option value="all" selected={@scope == "all"}>{gettext("All scopes")}</option>
            <option value="root" selected={@scope == "root"}>{gettext("Root (no company)")}</option>
            <option :for={c <- @companies} value={c} selected={@scope == c}>{c}</option>
          </select>
        </form>
        <p class="mt-1.5 px-1 text-[11px] leading-relaxed text-zinc-500">
          {gettext("Pick a company to see and configure only its agents, models and automations.")}
        </p>
        <form :if={@new_company} phx-submit="company_add" class="mt-2 flex gap-1">
          <input name="name" placeholder={gettext("company name")} required class={fld()} />
          <button class="rounded-lg bg-orange-600 px-3 text-sm font-medium hover:bg-orange-500">{gettext("Add")}</button>
        </form>
        <button phx-click="toggle_new_company" class="mt-1.5 px-1 text-[11px] text-zinc-500 transition hover:text-zinc-300">
          {(@new_company && gettext("Cancel")) || gettext("+ New company")}
        </button>
      </div>

      <nav class="flex-1 space-y-5 overflow-y-auto px-3 py-4">
        <div class="space-y-0.5">
          <div class={nav_group_cls()}>{gettext("Conversation")}</div>
          <.nav_item active={@active} to="chat" icon="💬" label={gettext("Chat")} />
        </div>
        <div class="space-y-0.5">
          <div class={nav_group_cls()}>{gettext("Build")}</div>
          <.nav_item active={@active} to="companies" icon="🏢" label={gettext("Companies")} />
          <.nav_item active={@active} to="agents" icon="🧩" label={gettext("Agents")} />
          <.nav_item active={@active} to="models" icon="🔌" label={gettext("Models")} />
          <.nav_item active={@active} to="mcp" icon="🧰" label="MCP" />
        </div>
        <div class="space-y-0.5">
          <div class={nav_group_cls()}>{gettext("Automation")}</div>
          <.nav_item active={@active} to="cron" icon="🕒" label={gettext("Scheduled")} />
          <.nav_item active={@active} to="watches" icon="🔭" label={gettext("Watches")} />
          <.nav_item active={@active} to="bots" icon="📡" label={gettext("Channels")} />
        </div>
        <div class="space-y-0.5">
          <div class={nav_group_cls()}>{gettext("Insight")}</div>
          <.nav_item active={@active} to="learn" icon="✦" label={gettext("Learning")} />
          <.nav_item active={@active} to="usage" icon="📊" label={gettext("Usage & billing")} />
        </div>
        <div class="space-y-0.5">
          <div class={nav_group_cls()}>{gettext("System")}</div>
          <.nav_item active={@active} to="config" icon="⚙️" label={gettext("Config file")} />
        </div>
      </nav>
      <div class="border-t border-zinc-800 px-5 py-3 text-[11px] text-zinc-600">
        {gettext("Local dashboard · localhost")}
      </div>
    </aside>
    """
  end

  attr :active, :string, required: true
  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={"/#{@to}"}
      class={[
        "flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition",
        (@active == @to && "bg-orange-600/15 font-medium text-orange-300") ||
          "text-zinc-400 hover:bg-zinc-800/70 hover:text-zinc-100"
      ]}
    >
      <span class="w-5 text-center text-base">{@icon}</span>
      <span>{@label}</span>
    </.link>
    """
  end
end
