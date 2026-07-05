defmodule PepeWeb.ChannelsLive do
  @moduledoc "Channels section: connect agents to messaging channels (Telegram + WhatsApp)."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Channels",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       bots: Config.telegram_bots(),
       widget_tokens: Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget")),
       widget_raw: nil,
       host: connected?(socket) && request_host(socket),
       edit_bot: nil,
       edit_widget: nil,
       adding: nil,
       adding_channel: false,
       form: nil,
       native_channels: native_channel_cards()
     )}
  end

  # The address this dashboard is being accessed at right now, so a widget's embed
  # snippet can be filled in with the real host instead of a placeholder.
  defp request_host(socket) do
    case get_connect_info(socket, :uri) do
      %URI{scheme: scheme, host: host, port: port} ->
        if port in [80, 443], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"

      _ ->
        nil
    end
  end

  # `t` is a widget token entry (string-keyed: "agent", "token", plus whatever
  # appearance fields are set). data-agent is never shown: a widget token is always
  # agent-locked, and ApiScope.authorize_agent/2 ignores the requested topic name
  # entirely for an agent-locked scope, so it would be dead weight in the snippet.
  # Appearance attrs only show up if actually SET on the token - anything left unset
  # is fetched from the dashboard at load time (PepeWeb.WidgetConfigController), so a
  # freshly-created widget with no customization renders just data-token. The site's
  # HTML can still set data-* attributes directly instead (or as well) - a token-set
  # value wins, an unset one falls through to the tag's own attribute.
  defp widget_snippet(host, t) do
    attrs =
      [
        # A widget minted before raw values started being stored has no "token" -
        # a placeholder beats silently omitting the attribute (which would leave
        # the pasted snippet quietly missing auth entirely).
        {"data-token", t["token"] || "pepe_YOUR_TOKEN_HERE"},
        {"data-title", t["title"]},
        {"data-logo", t["logo"]},
        {"data-color", t["color"]},
        {"data-theme", t["theme"]},
        {"data-greeting", t["greeting"]},
        {"data-position", t["position"]}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map_join("\n        ", fn {k, v} -> ~s(#{k}="#{attr(v)}") end)

    ~s(<script src="#{attr(host || "https://your-pepe-host")}/plugin-assets/pepe-widget/widget.js"\n        #{attrs}></script>)
  end

  # The appearance fields are free text the operator types, and this snippet is copied verbatim
  # into their own public site's HTML - so a value with a `"` or `<` would break out of the
  # attribute (or inject a tag) there, even though it renders as inert text inside the dashboard.
  # Escape each value for double-quoted-attribute context.
  defp attr(v), do: v |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # `values` is a widget token entry (or `%{}` for a fresh one) - reused by both the
  # create form and the edit form below, keyed by `prefix` so both can post-back
  # under their own form's namespace ("widget"/"widget_edit").
  attr :prefix, :string, required: true
  attr :values, :map, required: true

  defp widget_appearance_fields(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <div class="col-span-2">
        <label class={lbl()}>{gettext("Title")}</label>
        <input name={"#{@prefix}[title]"} value={@values["title"]} placeholder="Chat" class={fld()} />
      </div>
      <div class="col-span-2">
        <label class={lbl()}>{gettext("Logo URL")}</label>
        <input name={"#{@prefix}[logo]"} value={@values["logo"]} placeholder="https://example.com/logo.png" class={fld()} />
      </div>
      <div>
        <label class={lbl()}>{gettext("Color")}</label>
        <input name={"#{@prefix}[color]"} value={@values["color"]} placeholder="#ea580c" class={fld()} />
      </div>
      <div>
        <label class={lbl()}>{gettext("Theme")}</label>
        <select name={"#{@prefix}[theme]"} class={fld()}>
          <option value="" selected={blank(@values["theme"]) == nil}>{gettext("Light (default)")}</option>
          <option value="dark" selected={@values["theme"] == "dark"}>{gettext("Dark")}</option>
        </select>
      </div>
      <div class="col-span-2">
        <label class={lbl()}>{gettext("Greeting")}</label>
        <input name={"#{@prefix}[greeting]"} value={@values["greeting"]} placeholder="Hi! How can I help?" class={fld()} />
      </div>
      <div>
        <label class={lbl()}>{gettext("Position")}</label>
        <select name={"#{@prefix}[position]"} class={fld()}>
          <option value="" selected={blank(@values["position"]) == nil}>{gettext("Right (default)")}</option>
          <option value="left" selected={@values["position"] == "left"}>{gettext("Left")}</option>
        </select>
      </div>
    </div>
    """
  end

  defp bot_changeset(attrs) do
    {%{}, %{name: :string, token: :string, agent: :string}}
    |> Changeset.cast(attrs, [:name, :token, :agent])
    |> Changeset.validate_required([:name, :token])
    |> Changeset.validate_exclusion(:name, ["default"], message: gettext("pick another name"))
  end

  defp bot_form(attrs), do: to_form(bot_changeset(attrs), as: :bot)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :scoped_bots, scoped_by_agent(assigns.bots, assigns.scope, & &1["agent"]))
    assigns = assign(assigns, :scoped_widget_tokens, scoped_by_agent(assigns.widget_tokens, assigns.scope, & &1["agent"]))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="bots" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="📡"
          title={gettext("Channels")}
          desc={gettext("Connect your agents to messaging channels so people can chat with them: a Telegram bot, or a webhook channel like WhatsApp, Slack, Discord, Teams or Google Chat, each bound to an agent.")}
        >
          <button :if={!@edit_bot and @adding == nil} phx-click="restart_gateway"
            data-confirm={gettext("Restart the Telegram gateway now?")} class={btn_ghost()} title={gettext("Recovery: respawn the pollers if the gateway seems stuck")}>
            ↻ {gettext("Restart gateway")}
          </button>
          <button :if={@edit_bot} phx-click="bot_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
          <button :if={@adding != nil} phx-click="add_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-6">
          <%!-- LIST: channel groups only for what exists, plus one "Add a channel" picker --%>
          <div :if={!@edit_bot and @adding == nil} class="space-y-6">
            <%!-- One picker for every channel type: Telegram plus each webhook provider - kept at
                 the top so it's never buried below a growing list of existing channels --%>
            <div :if={not @adding_channel} class="border-b border-zinc-800 pb-5">
              <div class="mb-2 text-sm font-medium text-zinc-400">{gettext("Add a channel")}</div>
              <div class="flex flex-wrap gap-2">
                <button phx-click="add" phx-value-kind="bot" class={btn_ghost()}>{gettext("+ Telegram bot")}</button>
                <button :for={p <- @native_channels} phx-click="add_channel" phx-value-name={p.name} class={btn_ghost()}>
                  + {p.label}
                </button>
                <button phx-click="add" phx-value-kind="widget" class={btn_ghost()}>{gettext("+ Widget")}</button>
              </div>
              <p class="mt-2 text-sm text-zinc-500">
                {gettext("WhatsApp, Slack, Discord, Microsoft Teams and Google Chat connect over each platform's official webhook. Fill in the credentials, then register the Webhook URL shown in the provider. A widget is a chat bubble you embed with a script tag.")}
              </p>
            </div>

            <%!-- Just-minted widget token, with a ready-to-paste snippet --%>
            <div :if={@widget_raw} class="rounded-lg border border-amber-700/60 bg-amber-950/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0 text-sm">
                  <span class="font-semibold text-amber-200">{gettext("Widget created")}</span>
                  <span class="text-amber-200/70">- {gettext("paste this snippet on your site.")}</span>
                </div>
                <button phx-click="widget_dismiss" class="shrink-0 text-sm text-amber-200/70 hover:text-amber-200">{gettext("Dismiss")}</button>
              </div>
              <div class="mt-2 flex items-center gap-2">
                <code class="min-w-0 flex-1 select-all truncate rounded-lg border border-amber-800/60 bg-zinc-950 px-3 py-2 font-mono text-sm text-amber-100">{@widget_raw["token"]}</code>
                <.copy_button id="copy-widget-token" value={@widget_raw["token"]} class="shrink-0" />
              </div>
              <div class="mt-3">
                <div class="mb-1 text-sm text-amber-200/80">{gettext("Paste this on your site:")}</div>
                <div class="flex items-start gap-2">
                  <pre class="min-w-0 flex-1 overflow-x-auto rounded-lg border border-amber-800/60 bg-zinc-950 px-3 py-2 font-mono text-xs text-amber-100">{widget_snippet(@host, @widget_raw)}</pre>
                  <.copy_button id="copy-widget-snippet" value={widget_snippet(@host, @widget_raw)} class="shrink-0" />
                </div>
              </div>
            </div>

            <%!-- Telegram group (long-poll gateway): only when it has bots --%>
            <div :if={not @adding_channel and @scoped_bots != []}>
              <div class="mb-2 flex items-center gap-2 font-medium">
                <span>{gettext("Telegram")}</span>
                <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-xs text-zinc-400">telegram</span>
              </div>

              <div :for={b <- @scoped_bots} class={[card(), "mb-2"]}>
                <div class="flex items-center justify-between gap-2">
                  <div class="min-w-0">
                    <span class="font-medium">{b["name"]}</span>
                    <span class={["ml-2 rounded px-1.5 text-sm", bot_active?(b) && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                      {(bot_active?(b) && gettext("active")) || gettext("inactive")}
                    </span>
                  </div>
                  <div class="flex shrink-0 gap-1 text-sm">
                    <button phx-click="bot_edit" phx-value-name={b["name"]} class={btn_ghost()}>{gettext("Edit")}</button>
                    <button phx-click="bot_remove" phx-value-name={b["name"]}
                      data-confirm={gettext("Remove bot %{name}?", name: b["name"])} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
                  </div>
                </div>
                <div class="mt-1 text-sm text-zinc-400">{gettext("Agent:")} {b["agent"] || gettext("(default)")}</div>
                <div class="text-sm text-zinc-500">{gettext("Token:")} {token_hint(b["bot_token"])}</div>
              </div>
            </div>

            <%!-- Widget group: only when a widget token exists in this scope --%>
            <div :if={not @adding_channel and @scoped_widget_tokens != []}>
              <div class="mb-2 flex items-center gap-2 font-medium">
                <span>{gettext("Widget")}</span>
                <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-xs text-zinc-400">widget</span>
              </div>

              <div :for={t <- @scoped_widget_tokens} class={[card(), "mb-2"]}>
                <div class="flex items-center justify-between gap-2">
                  <div class="min-w-0">
                    <span class="font-medium">{t["label"] || gettext("Unlabeled")}</span>
                  </div>
                  <div class="flex shrink-0 gap-2">
                    <button phx-click="widget_edit" phx-value-id={t["id"]} class={btn_ghost()}>
                      {if @edit_widget == t["id"], do: gettext("Cancel"), else: gettext("Edit appearance")}
                    </button>
                    <.link navigate={~p"/tokens?scope=#{@scope}"} class={btn_ghost()}>{gettext("Manage token")}</.link>
                  </div>
                </div>
                <div class="mt-1 text-sm text-zinc-400">{gettext("Agent:")} {t["agent"] || gettext("(default)")}</div>
                <div class="text-sm text-zinc-500">{gettext("Origin:")} {t["allowed_origin"] || gettext("no origin set")}</div>
                <p class={hlp()}>{gettext("To point this widget at a different agent or origin, create a new one and revoke this one - agent/origin can't change after minting, but appearance can, right here.")}</p>

                <form :if={@edit_widget == t["id"]} phx-submit="widget_edit_save" class="mt-3 border-t border-zinc-800 pt-3">
                  <input type="hidden" name="widget_id" value={t["id"]} />
                  <.widget_appearance_fields prefix="widget_edit" values={t} />
                  <div class="mt-3 flex gap-2">
                    <button type="submit" class={btn()}>{gettext("Save appearance")}</button>
                  </div>
                </form>

                <details class="mt-2">
                  <summary class="cursor-pointer text-sm text-zinc-400 hover:text-zinc-200">{gettext("Embed snippet")}</summary>
                  <div class="mt-1 flex items-start gap-2">
                    <pre class="min-w-0 flex-1 overflow-x-auto rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-300">{widget_snippet(@host, t)}</pre>
                    <.copy_button id={"copy-widget-snippet-#{t["id"]}"} value={widget_snippet(@host, t)} class="shrink-0" />
                  </div>
                </details>
              </div>
            </div>

            <%!-- Webhook groups (only those with a connection) or the open connection form --%>
            <.live_component
              module={PepeWeb.ConnectionsComponent}
              id="native-channels"
              providers={@native_channels}
              scope={@scope}
              projects={@projects}
              show_picker={false}
            />

          </div>

          <%!-- ADD A WIDGET --%>
          <div :if={@adding == :widget} class="max-w-2xl">
            <form phx-submit="widget_add" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("+ Add a widget")}</div>
              <div>
                <label class={lbl()}>{gettext("Label")} <span class="text-zinc-600">{gettext("(optional)")}</span></label>
                <input name="widget[label]" placeholder={gettext("example.com widget")} class={fld()} />
              </div>
              <div>
                <label class={lbl()}>{gettext("Agent")}</label>
                <select name="widget[agent]" class={fld()}>
                  <option value="">{gettext("Choose an agent...")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                </select>
                <p class={hlp()}>{gettext("A widget always pins to one agent - never a whole workspace.")}</p>
              </div>
              <div>
                <label class={lbl()}>{gettext("Allowed origin")}</label>
                <input name="widget[allowed_origin]" placeholder="https://example.com" class={fld()} />
                <p class={hlp()}>{gettext("The site's scheme + host. The widget's connection is refused from anywhere else.")}</p>
              </div>
              <div class="border-t border-zinc-800 pt-4">
                <div class="mb-1 text-sm font-medium text-zinc-300">{gettext("Appearance")}</div>
                <p class={hlp()}>{gettext("Optional - leave blank to use the embed snippet's own data-* attributes. Editable here later without touching the site.")}</p>
                <.widget_appearance_fields prefix="widget" values={%{}} />
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Create widget")}</button>
                <button type="button" phx-click="add_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </form>
          </div>

          <%!-- EDIT A TELEGRAM BOT --%>
          <div :if={@edit_bot} class="max-w-2xl">
            <form phx-submit="bot_save" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("Edit %{name}", name: @edit_bot["name"])}</div>
              <input type="hidden" name="name" value={@edit_bot["name"]} />
              <div>
                <label class={lbl()}>{gettext("This bot talks to")}</label>
                <select name="agent" class={fld()}>
                  <option value="">{gettext("The default agent")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @edit_bot["agent"]}>{a}</option>
                </select>
              </div>
              <div>
                <label class={lbl()}>{gettext("While the agent works")}</label>
                <select name="tool_progress" class={fld()}>
                  <option value="reaction" selected={(@edit_bot["tool_progress"] || "reaction") == "reaction"}>{gettext("React (default)")}</option>
                  <option value="verbose" selected={@edit_bot["tool_progress"] == "verbose"}>{gettext("Detailed")}</option>
                  <option value="ambient" selected={@edit_bot["tool_progress"] == "ambient"}>{gettext("Ambient")}</option>
                  <option value="off" selected={@edit_bot["tool_progress"] == "off"}>{gettext("Nothing")}</option>
                </select>
                <div class="mt-2 space-y-1 text-sm text-zinc-400">
                  <p>
                    <span class="text-zinc-200">👀 {gettext("React")}</span> ({gettext("default")}) — {gettext("just a 👀 dropped on your message while it works, cleared when the reply lands. The quietest signal.")}
                  </p>
                  <p>
                    <span class="text-zinc-200">🛠️ {gettext("Detailed")}</span> — {gettext("a live activity log: every tool the agent uses and the reason it reached for it, so you can follow exactly what it's doing.")}
                  </p>
                  <p>
                    <span class="text-zinc-200">💬 {gettext("Ambient")}</span> — {gettext("a single line describing the kind of work happening, with no tool names or per-step detail.")}
                  </p>
                  <p>
                    <span class="text-zinc-200">🚫 {gettext("Nothing")}</span> — {gettext("no status message at all, just Telegram's native typing indicator.")}
                  </p>
                  <p class="pt-0.5 text-zinc-600">{gettext("Whichever you pick, the status message updates in place and is removed when the answer arrives, so only the reply stays in the chat.")}</p>
                </div>
              </div>
              <div>
                <label class="flex items-center gap-2">
                  <input type="checkbox" name="require_approval" value="true" checked={@edit_bot["require_approval"] == true} />
                  <span class={lbl()}>{gettext("Require approval for new users")}</span>
                </label>
                <p class={hlp()}>{gettext("When on, the bot ignores anyone not on its allowlist and lists them below for you to let in with one click. When off, it answers everyone (unless you set an explicit user allowlist).")}</p>
              </div>
              <div>
                <label class={lbl()}>{gettext("Bot token")} <span class="text-zinc-600">{gettext("(leave blank to keep the current one)")}</span></label>
                <input name="token" placeholder={"${TELEGRAM_BOT_TOKEN}  " <> gettext("(or paste a new token)")} class={fld()} />
                <p class={hlp()}>{gettext("Tip: use an env-var reference like ${MY_BOT_TOKEN} to keep the secret out of the config file.")}</p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Save")}</button>
                <button type="button" phx-click="bot_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </form>

            <%!-- USERS WAITING FOR APPROVAL (outside the form, so a button never submits it) --%>
            <div :if={@edit_bot["require_approval"] == true} class="mt-6 border-t border-zinc-800 pt-4">
              <div class="text-sm font-semibold">{gettext("Waiting for approval")}</div>
              <p :if={pending_users(@edit_bot) == []} class={hlp()}>{gettext("No one is waiting.")}</p>
              <div
                :for={u <- pending_users(@edit_bot)}
                class="mt-2 flex items-center justify-between gap-2 rounded bg-zinc-900 px-2 py-1.5"
              >
                <div class="min-w-0">
                  <div class="text-sm text-zinc-200">
                    {u["name"]} <span class="font-mono text-xs text-zinc-500">id {u["id"]}</span>
                  </div>
                  <div class="truncate text-xs text-zinc-500">{u["sample"]}</div>
                </div>
                <div class="flex shrink-0 gap-1">
                  <button phx-click="bot_approve_user" phx-value-name={@edit_bot["name"]} phx-value-id={u["id"]} class={btn()}>
                    {gettext("Add")}
                  </button>
                  <button phx-click="bot_dismiss_user" phx-value-name={@edit_bot["name"]} phx-value-id={u["id"]} class={btn_ghost()}>
                    {gettext("Ignore")}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- ADD A TELEGRAM BOT --%>
          <div :if={@adding == :bot} class="max-w-2xl">
            <.form for={@form} phx-submit="bot_add" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("+ Add a bot")}</div>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("sales")} />
              <div>
                <.input field={@form[:token]} label={gettext("Bot token")} placeholder="123456:ABC...  or  ${SALES_BOT_TOKEN}" />
                <p class={hlp()}>{gettext("From @BotFather. Tip: use an env-var reference to keep the token out of the config file.")}</p>
              </div>
              <div>
                <label class={lbl()}>{gettext("This bot talks to")}</label>
                <select name="bot[agent]" class={fld()}>
                  <option value="">{gettext("The default agent")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                </select>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Add bot")}</button>
                <button type="button" phx-click="add_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>

        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("add", %{"kind" => "widget"}, socket) do
    {:noreply, assign(socket, adding: :widget, edit_bot: nil)}
  end

  def handle_event("add", %{"kind" => _kind}, socket) do
    {:noreply, assign(socket, adding: :bot, edit_bot: nil, form: bot_form(%{}))}
  end

  def handle_event("add_cancel", _p, socket), do: {:noreply, assign(socket, adding: nil)}

  def handle_event("widget_add", %{"widget" => p}, socket) do
    opts = [
      label: blank(p["label"]),
      agent: blank(p["agent"]),
      widget: true,
      allowed_origin: blank(p["allowed_origin"]),
      title: blank(p["title"]),
      logo: blank(p["logo"]),
      color: blank(p["color"]),
      theme: blank(p["theme"]),
      greeting: blank(p["greeting"]),
      position: blank(p["position"])
    ]

    case Config.add_api_token(opts) do
      {:ok, _raw, id} ->
        tokens = Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget"))

        {:noreply,
         assign(socket,
           widget_tokens: tokens,
           widget_raw: Enum.find(tokens, &(&1["id"] == id)),
           adding: nil
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, widget_error(reason))}
    end
  end

  def handle_event("widget_dismiss", _p, socket), do: {:noreply, assign(socket, widget_raw: nil)}

  def handle_event("widget_edit", %{"id" => id}, socket) do
    next = if socket.assigns.edit_widget == id, do: nil, else: id
    {:noreply, assign(socket, edit_widget: next)}
  end

  def handle_event("widget_edit_save", %{"widget_id" => id, "widget_edit" => p}, socket) do
    # No `label:` here - this form only edits appearance, and update_widget_token/2
    # leaves label untouched unless the caller passes it explicitly.
    opts = [
      title: blank(p["title"]),
      logo: blank(p["logo"]),
      color: blank(p["color"]),
      theme: blank(p["theme"]),
      greeting: blank(p["greeting"]),
      position: blank(p["position"])
    ]

    case Config.update_widget_token(id, opts) do
      :ok ->
        {:noreply,
         assign(socket,
           widget_tokens: Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget")),
           edit_widget: nil
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't save - the widget may have been removed."))}
    end
  end

  # Open a webhook channel's form inside the shared component (which lives in this page).
  def handle_event("add_channel", %{"name" => name}, socket) do
    send_update(PepeWeb.ConnectionsComponent, id: "native-channels", open: name)
    {:noreply, assign(socket, adding_channel: true)}
  end

  def handle_event("bot_add", %{"bot" => p}, socket) do
    cs =
      p
      |> bot_changeset()
      |> then(fn cs ->
        # Two bots on one token would 409 against each other on getUpdates.
        if token_taken?(p["token"], nil),
          do: Changeset.add_error(cs, :token, gettext("this token is already used by another bot")),
          else: cs
      end)

    if cs.valid? do
      name = Changeset.get_field(cs, :name) |> String.trim()

      Config.put_telegram_bot(
        name,
        reject_nil(%{"bot_token" => p["token"], "agent" => blank(p["agent"])})
      )

      reload_gateways()

      {:noreply,
       socket
       |> assign(bots: Config.telegram_bots(), adding: nil)
       |> put_flash(:info, gettext("Bot %{name} added.", name: name))}
    else
      {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :bot))}
    end
  end

  def handle_event("bot_remove", %{"name" => name}, socket) do
    Config.delete_telegram_bot(name)
    reload_gateways()
    {:noreply, assign(socket, bots: Config.telegram_bots())}
  end

  def handle_event("restart_gateway", _p, socket) do
    Pepe.Gateways.Supervisor.restart_telegram()
    {:noreply, put_flash(socket, :info, gettext("Telegram gateway restarted."))}
  end

  def handle_event("bot_edit", %{"name" => name}, socket) do
    {:noreply, assign(socket, edit_bot: Config.telegram_bot(name), adding: nil)}
  end

  def handle_event("bot_cancel", _p, socket), do: {:noreply, assign(socket, edit_bot: nil)}

  def handle_event("bot_approve_user", %{"name" => name, "id" => id}, socket) do
    Config.approve_telegram_user(name, String.to_integer(id))
    reload_gateways()

    {:noreply,
     socket
     |> assign(bots: Config.telegram_bots(), edit_bot: Config.telegram_bot(name))
     |> put_flash(:info, gettext("User added. They can talk to the bot now."))}
  end

  def handle_event("bot_dismiss_user", %{"name" => name, "id" => id}, socket) do
    Config.dismiss_telegram_pending(name, String.to_integer(id))
    {:noreply, assign(socket, edit_bot: Config.telegram_bot(name))}
  end

  def handle_event("bot_save", %{"name" => name} = params, socket) do
    new_token = blank(params["token"])

    if new_token && token_taken?(new_token, name) do
      {:noreply, put_flash(socket, :error, gettext("That token is already used by another bot."))}
    else
      bot =
        (Config.telegram_bot(name) || %{})
        |> Map.delete("name")
        |> put_or_delete("agent", blank(params["agent"]))
        |> put_or_delete("tool_progress", blank(params["tool_progress"]))
        |> Map.put("require_approval", params["require_approval"] == "true")
        |> maybe_put_token(new_token)

      save_bot(name, bot)
      reload_gateways()

      {:noreply,
       socket
       |> assign(bots: Config.telegram_bots(), edit_bot: nil)
       |> put_flash(:info, gettext("Bot %{name} saved.", name: name))}
    end
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/bots")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  @impl true
  def handle_info({:flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:channel_form, :closed}, socket), do: {:noreply, assign(socket, adding_channel: false)}

  # Does another bot (any but `exclude_name`) already resolve to this token? Compares
  # interpolated values so two ${ENV_VAR} refs to the same secret are caught too.
  defp maybe_put_token(bot, nil), do: bot
  defp maybe_put_token(bot, token), do: Map.put(bot, "bot_token", token)

  # Users this bot blocked (deny-by-default under require_approval) that are waiting to be let in.
  defp pending_users(%{"name" => name}), do: Config.telegram_pending(name)
  defp pending_users(_), do: []

  defp token_taken?(token, exclude_name) do
    want = Config.interpolate(token) || token

    Config.telegram_bots()
    |> Enum.reject(&(&1["name"] == exclude_name))
    |> Enum.any?(fn b -> (Config.interpolate(b["bot_token"]) || b["bot_token"]) == want end)
  end

  defp widget_error(:unknown_project), do: gettext("That project does not exist.")
  defp widget_error(:agent_out_of_scope), do: gettext("That agent is not in the chosen project.")
  defp widget_error(:unknown_agent), do: gettext("That agent does not exist.")
  defp widget_error(:widget_needs_agent), do: gettext("Pick an agent for this widget.")
end
