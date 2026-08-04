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
      "w-full rounded-lg border border-zinc-800 bg-zinc-950 px-3.5 py-2.5 text-[15px] text-zinc-100 outline-none transition placeholder:text-zinc-600 focus:border-orange-500 focus:ring-1 focus:ring-orange-500"

  def lbl, do: "mb-1.5 block text-sm font-medium text-zinc-300"
  def hlp, do: "mt-1.5 text-sm leading-relaxed text-zinc-500"

  def card,
    do: "rounded-xl border border-zinc-800 bg-zinc-900/50 p-5 transition hover:border-zinc-700"

  def btn,
    do:
      "inline-flex items-center justify-center rounded-lg bg-orange-600 px-4 py-2 text-sm font-semibold text-white transition hover:bg-orange-500"

  def btn_ghost,
    do:
      "inline-flex items-center justify-center rounded-lg border border-zinc-800 bg-zinc-900 px-3.5 py-2 text-sm text-zinc-300 transition hover:border-zinc-700 hover:text-white"

  defp nav_group_cls,
    do: "px-3 pb-1 text-xs font-semibold uppercase tracking-wider text-zinc-600"

  @doc """
  The root of a section's page: the flex row that holds the sidebar and the `<main>`.
  `h-dvh` rather than `h-screen` so a mobile browser's collapsing address bar doesn't
  push the bottom of the page (a chat composer, a form's buttons) out of reach.
  """
  def shell_cls, do: "flex h-dvh overflow-hidden bg-zinc-950 text-zinc-100"

  @doc """
  The scrollable body of a section, under its header. Tighter padding on a phone,
  where 24px of chrome on each side is a sixth of the screen.
  """
  def body_cls, do: "flex-1 overflow-y-auto p-4 sm:p-6"

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
  slot :inner_block, required: true

  @doc """
  A titled group of related fields inside a form - groups a long flat form into
  scannable chunks (e.g. "Connection", "Reliability", "Billing") instead of one
  undifferentiated list of inputs.
  """
  def form_section(assigns) do
    ~H"""
    <div :if={!@collapsible} class="space-y-6 rounded-xl border border-zinc-800/80 bg-zinc-900/30 p-4 sm:p-6">
      <div class="border-b border-zinc-800 pb-3 text-sm font-semibold uppercase tracking-wide text-zinc-200">
        {@title}
      </div>
      {render_slot(@inner_block)}
    </div>
    <details :if={@collapsible} open={@open} class="group rounded-xl border border-zinc-800/80 bg-zinc-900/30">
      <summary class="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-sm font-semibold uppercase tracking-wide text-zinc-200 marker:hidden [&::-webkit-details-marker]:hidden sm:px-6 sm:py-4">
        {@title}
        <.icon name="hero-chevron-down" class="size-4 shrink-0 text-zinc-500 transition group-open:rotate-180" />
      </summary>
      <div class="space-y-6 border-t border-zinc-800 p-4 sm:p-6">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  slot :inner_block

  @doc """
  A consistent header for a section: icon + title, a one-line description, and optional
  actions. Below `md` the actions drop under the title instead of fighting it for width,
  and the hamburger that opens the nav drawer sits to the left of the title.
  """
  def view_header(assigns) do
    ~H"""
    <header class="flex flex-col gap-3 border-b border-zinc-800 px-4 py-4 md:flex-row md:items-center md:justify-between md:gap-4 md:px-7 md:py-6">
      <div class="flex min-w-0 items-start gap-3">
        <.nav_toggle />
        <div class="min-w-0">
          <div class="flex items-center gap-3 text-xl font-bold tracking-tight sm:text-2xl">
            <span>{@icon}</span> <span class="truncate">{@title}</span>
          </div>
          <div class="mt-2 max-w-3xl text-[15px] leading-relaxed text-zinc-400 sm:text-base">{@desc}</div>
        </div>
      </div>
      <div class="flex shrink-0 flex-wrap items-center gap-2">{render_slot(@inner_block)}</div>
    </header>
    """
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
    <aside class="fixed inset-y-0 left-0 z-40 flex w-[17rem] max-w-[85vw] -translate-x-full flex-col border-r border-zinc-800 bg-zinc-950 transition-transform duration-200 ease-out peer-checked:translate-x-0 md:static md:z-auto md:w-64 md:max-w-none md:shrink-0 md:translate-x-0 md:bg-zinc-900/40">
      <.link navigate={~p"/"} class="flex items-center gap-2.5 border-b border-zinc-800 px-5 py-5">
        <svg width="28" height="38" viewBox="16 8 32 44" class="mt-1 shrink-0" role="img" aria-label="Pepe">
          <g stroke="#a1a1aa" stroke-width="3" stroke-linecap="round" fill="none">
            <path d="M26 22 L 21 13" />
            <path d="M38 22 L 43 13" />
          </g>
          <circle cx="20.5" cy="12" r="3.2" fill="#e2231a" />
          <circle cx="43.5" cy="12" r="3.2" fill="#f5b301" />
          <rect x="18" y="22" width="28" height="27" rx="9" fill="none" stroke="#e4e4e7" stroke-width="3.4" />
        </svg>
        <div class="leading-tight">
          <div class="text-lg font-semibold">Pepe</div>
          <div class="text-xs text-zinc-500">{gettext("agent runtime")}</div>
        </div>
      </.link>

      <div class="border-b border-zinc-800 px-3 py-3">
        <label class="mb-1 block px-1 text-xs font-semibold uppercase tracking-wider text-zinc-600">
          {gettext("Project")}
        </label>
        <form id="scope-form" phx-change="set_scope">
          <select name="scope" class={fld()}>
            <option value="all" selected={@scope == "all"}>{gettext("All projects")}</option>
            <option value="root" selected={@scope == "root"}>{gettext("Principal")}</option>
            <option :for={c <- @projects} value={c} selected={@scope == c}>{c}</option>
          </select>
        </form>
        <p class="mt-1.5 px-1 text-xs leading-relaxed text-zinc-500">
          {gettext("Pick a project to see and configure only its agents, models and automations.")}
        </p>
        <form :if={@new_project} phx-submit="project_add" class="mt-2 flex gap-1">
          <input name="name" placeholder={gettext("project name")} required class={fld()} />
          <button class="rounded-lg bg-orange-600 px-3 text-[15px] font-medium hover:bg-orange-500">{gettext("Add")}</button>
        </form>
        <button phx-click="toggle_new_project" class="mt-1.5 px-1 text-xs text-zinc-500 transition hover:text-zinc-300">
          {(@new_project && gettext("Cancel")) || gettext("+ New project")}
        </button>
      </div>

      <nav class="flex-1 space-y-6 overflow-y-auto px-3 py-5">
        <div class="space-y-1">
          <.nav_item active={@active} scope={@scope} to="overview" icon="🏠" label={gettext("Overview")} />
          <.nav_item active={@active} scope={@scope} to="chat" icon="💬" label={gettext("Chat")} />
        </div>
        <div class="space-y-1">
          <div class={nav_group_cls()}>{gettext("Build")}</div>
          <.nav_item active={@active} scope={@scope} to="projects" icon="🏢" label={gettext("Projects")} />
          <.nav_item active={@active} scope={@scope} to="agents" icon="🧩" label={gettext("Agents")} />
          <.nav_item active={@active} scope={@scope} to="models" icon="🔌" label={gettext("Models")} />
          <.nav_item active={@active} scope={@scope} to="mcp" icon="🧰" label="MCP" />
          <.nav_item active={@active} scope={@scope} to="databases" icon="🗄️" label={gettext("Databases")} />
          <.nav_item active={@active} scope={@scope} to="plugins" icon="🧩" label={gettext("Plugins")} />
        </div>
        <div class="space-y-1">
          <div class={nav_group_cls()}>{gettext("Automation")}</div>
          <.nav_item active={@active} scope={@scope} to="cron" icon="🕒" label={gettext("Scheduled")} />
          <.nav_item active={@active} scope={@scope} to="board" icon="🗂️" label={gettext("Board")} />
          <.nav_item active={@active} scope={@scope} to="watches" icon="🔭" label={gettext("Watches")} />
          <.nav_item active={@active} scope={@scope} to="commitments" icon="🤝" label={gettext("Commitments")} />
          <.nav_item active={@active} scope={@scope} to="bots" icon="📡" label={gettext("Channels")} />
          <.nav_item active={@active} scope={@scope} to="integrations" icon="🔌" label={gettext("Integrations")} />
        </div>
        <div class="space-y-1">
          <div class={nav_group_cls()}>{gettext("Insight")}</div>
          <.nav_item active={@active} scope={@scope} to="learn" icon="✦" label={gettext("Learning")} />
          <.nav_item active={@active} scope={@scope} to="usage" icon="📊" label={gettext("Usage & billing")} />
          <.nav_item active={@active} scope={@scope} to="traces" icon="🧵" label={gettext("Traces")} />
          <.nav_item active={@active} scope={@scope} to="hooks" icon="🛡️" label={gettext("Privacy")} />
        </div>
        <div class="space-y-1">
          <div class={nav_group_cls()}>{gettext("System")}</div>
          <.nav_item active={@active} scope={@scope} to="tokens" icon="🔑" label={gettext("API tokens")} />
          <.nav_item active={@active} scope={@scope} to="config" icon="⚙️" label={gettext("Config file")} />
        </div>
      </nav>
      <div class="border-t border-zinc-800 px-5 py-3 text-xs text-zinc-600">
        <.link :if={Pepe.Config.dashboard_auth_required?()} href="/logout" method="delete" class="mb-1 block text-zinc-500 transition hover:text-zinc-300">
          {gettext("Sign out")}
        </.link>
        {gettext("Local dashboard · localhost")}
      </div>
    </aside>

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
      class={[
        "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left text-[15px] transition",
        (@active == @to && "bg-orange-600/15 font-medium text-orange-300") ||
          "text-zinc-400 hover:bg-zinc-800/70 hover:text-zinc-100"
      ]}
    >
      <span class="w-6 text-center text-lg">{@icon}</span>
      <span>{@label}</span>
    </.link>
    """
  end

  # Keep the selected project (scope) across navigation by carrying it in the URL.
  defp nav_href(to, scope) when scope in [nil, "", "all"], do: "/#{to}"
  defp nav_href(to, scope), do: "/#{to}?scope=#{scope}"
end
