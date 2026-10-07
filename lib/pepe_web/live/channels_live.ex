defmodule PepeWeb.ChannelsLive do
  @moduledoc "Channels section: connect agents to messaging channels (Telegram + WhatsApp)."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData
  import PepeWeb.TrainersPicker, only: [rename_form: 1, trainers_picker: 1]

  alias Ecto.Changeset
  alias Pepe.Config
  alias Pepe.Labels
  alias PepeWeb.TrainersPicker

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe: Channels",
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
       native_channels: native_channel_cards(),
       renaming_bot: nil,
       renaming_person: nil,
       bot_trainers: nil,
       bot_people: []
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

  # A widget colour is free text an operator typed, and the swatch drops it straight into a
  # `style` attribute - so only a value that IS a hex colour is ever echoed back there.
  @hex_color ~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/

  defp hex_color?(v), do: is_binary(v) and Regex.match?(@hex_color, v)

  defp hex_or_transparent(v), do: if(hex_color?(v), do: v, else: "transparent")

  # nil (left blank) is fine - it just falls through to the embed snippet's own data-color.
  defp color_error(nil), do: nil

  defp color_error(v) when is_binary(v) do
    if hex_color?(v), do: nil, else: gettext("The color must be a hex code like #ea580c.")
  end

  # `values` is a widget token entry (or `%{}` for a fresh one) - reused by both the
  # create form and the edit form below, keyed by `prefix` so both can post-back
  # under their own form's namespace ("widget"/"widget_edit").
  attr :prefix, :string, required: true
  attr :values, :map, required: true

  defp widget_appearance_fields(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <div class="col-span-2">
        <label class={lbl()}>{gettext("Title")}</label>
        <input name={"#{@prefix}[title]"} value={@values["title"]} placeholder={gettext("Chat")} class={fld()} />
      </div>
      <div class="col-span-2">
        <label class={lbl()}>{gettext("Logo URL")}</label>
        <input name={"#{@prefix}[logo]"} value={@values["logo"]} placeholder="https://example.com/logo.png" class={fld()} />
      </div>
      <div>
        <label class={lbl()}>{gettext("Color")}</label>
        <%!-- Typed by hand rather than picked: a colour input can never be empty (it falls back to
             #000000), and an unset colour has to stay unset so the embed snippet's own data-color
             still wins. The swatch beside it previews whatever was typed, and `pattern` refuses a
             malformed hex before the form is ever submitted. --%>
        <div class="flex items-center gap-2">
          <input
            name={"#{@prefix}[color]"}
            value={@values["color"]}
            placeholder="#ea580c"
            pattern="#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})"
            title={gettext("A hex color code like #ea580c")}
            class={[fld(), "min-w-0 flex-1 font-mono"]}
          />
          <span
            class="h-9 w-9 shrink-0 rounded-lg border border-zinc-700"
            style={"background-color: #{hex_or_transparent(@values["color"])}"}
          />
        </div>
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
        <input name={"#{@prefix}[greeting]"} value={@values["greeting"]} placeholder={gettext("Hi! How can I help?")} class={fld()} />
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
    |> Changeset.validate_exclusion(:name, ["default"], message: gettext("Pick another name"))
  end

  defp bot_form(attrs), do: to_form(bot_changeset(attrs), as: :bot)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :scoped_bots, scoped_by_agent(assigns.bots, assigns.scope, & &1["agent"]))
    assigns = assign(assigns, :scoped_widget_tokens, scoped_by_agent(assigns.widget_tokens, assigns.scope, & &1["agent"]))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="bots" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header active="bots"
          icon="📡"
          title={gettext("Channels")}
          desc={gettext("Let people chat with your agents in Telegram, WhatsApp, Slack, Discord, Teams or Google Chat. Each channel talks to one agent.")}
        >
          <button :if={!@edit_bot and @adding == nil and not @adding_channel} phx-click="restart_gateway"
            data-confirm={gettext("Restart the Telegram gateway now?")} class={btn_ghost()} title={gettext("Recovery: respawn the pollers if the gateway seems stuck")}>
            ↻ {gettext("Restart Telegram")}
          </button>
          <button :if={@edit_bot} phx-click="bot_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
          <button :if={@adding != nil} phx-click="add_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
          <button :if={@adding_channel} phx-click="channel_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
        </.view_header>
        <div class="page-body flex-1 overflow-y-auto px-4 pb-8 pt-1 sm:px-8 xl:px-14">
          <%!-- LIST: channel groups only for what exists, plus one "Add a channel" picker --%>
          <div :if={!@edit_bot and @adding == nil} class="space-y-6">
            <%!-- One picker for every channel type: Telegram plus each webhook provider - kept at
                 the top so it's never buried below a growing list of existing channels --%>
            <div :if={not @adding_channel} class="border-b border-zinc-800 pb-5">
              <div class={[eyebrow(), "mb-3"]}>{gettext("Add a channel")}</div>
              <div class="flex flex-wrap gap-2">
                <button phx-click="add" phx-value-kind="bot" class={btn_ghost()}>{gettext("+ Telegram bot")}</button>
                <button :for={p <- @native_channels} phx-click="add_channel" phx-value-name={p.name} class={btn_ghost()}>
                  + {p.label}
                </button>
                <button phx-click="add" phx-value-kind="widget" class={btn_ghost()}>{gettext("+ Widget")}</button>
              </div>
              <p class="mt-2 text-sm text-zinc-500">
                {gettext("Fill in the details, then paste the Webhook URL into the provider's settings.")}
              </p>
            </div>

            <%!-- Just-minted widget token, with a ready-to-paste snippet --%>
            <div :if={@widget_raw && not @adding_channel} class="rounded-lg border border-orange-400/40 bg-orange-400/[.05] p-3">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <div class="min-w-0 text-sm">
                  <span class="font-semibold text-amber-200">{gettext("Widget created")}</span>
                  <span class="text-amber-200/70">- {gettext("paste this code on your website.")}</span>
                </div>
                <button phx-click="widget_dismiss" class="shrink-0 text-sm text-amber-200/70 hover:text-amber-200">{gettext("Dismiss")}</button>
              </div>
              <div class="mt-2 flex items-center gap-2">
                <code class="min-w-0 flex-1 select-all truncate rounded-lg border border-amber-800/60 bg-zinc-950 px-3 py-2 font-mono text-sm text-amber-100">{@widget_raw["token"]}</code>
                <.copy_button id="copy-widget-token" value={@widget_raw["token"]} class="shrink-0" />
              </div>
              <div class="mt-3">
                <div class="mb-1 text-sm text-amber-200/80">{gettext("Paste this on your website:")}</div>
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
                <span class={tag(:muted)}>telegram</span>
              </div>

              <div :for={b <- @scoped_bots} class={[card(), "mb-2"]}>
                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <.named :if={@renaming_bot != b["name"]} text={Labels.connection(b["name"], b).text} id={b["name"]} class="font-medium" />
                    <button
                      :if={@renaming_bot != b["name"]}
                      type="button"
                      phx-click="bot_rename"
                      phx-value-name={b["name"]}
                      title={gettext("Rename")}
                      class="text-zinc-600 transition hover:text-zinc-200"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                    </button>
                    <%!-- Display only: the bot's name stays the identity, it is in every session key. --%>
                    <form :if={@renaming_bot == b["name"]} phx-submit="bot_save_label" class="flex flex-wrap items-center gap-1">
                      <input type="hidden" name="name" value={b["name"]} />
                      <input name="label" value={b["label"] || ""} maxlength="60" placeholder={b["name"]} class={[fld_sm(), "h-[36px] w-56 py-1 text-[14px]"]} />
                      <button type="submit" class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>{gettext("Save")}</button>
                      <button type="button" phx-click="bot_clear_label" phx-value-name={b["name"]} class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>
                        {gettext("Clear")}
                      </button>
                    </form>
                    <span class={tag((bot_active?(b) && :ok) || :muted)}>
                      {(bot_active?(b) && gettext("active")) || gettext("inactive")}
                    </span>
                  </div>
                  <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                    <button phx-click="bot_edit" phx-value-name={b["name"]} class={btn_ghost()}>{gettext("Edit")}</button>
                    <button phx-click="bot_remove" phx-value-name={b["name"]}
                      data-confirm={gettext("Remove bot %{name}?", name: Labels.connection(b["name"], b).text)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
                  </div>
                </div>
                <.meta_list class="mt-4">
                  <:item label={gettext("Agent:")}>{b["agent"] || gettext("(default)")}</:item>
                  <:item label={gettext("Token:")} mono>{token_hint(b["bot_token"])}</:item>
                </.meta_list>
                <%!-- The groups, topics and chats this bot has heard from, each bindable to an agent. --%>
                <.live_component
                  module={PepeWeb.SeenChannelsComponent}
                  id={"seen-telegram-" <> b["name"]}
                  connection={b["name"]}
                  provider="telegram"
                  agent={b["agent"]}
                  agents={scoped_agent_names(@scope)}
                  controls={:telegram}
                />
              </div>
            </div>

            <%!-- Widget group: only when a widget token exists in this scope --%>
            <div :if={not @adding_channel and @scoped_widget_tokens != []}>
              <div class="mb-2 flex items-center gap-2 font-medium">
                <span>{gettext("Widget")}</span>
                <span class={tag(:muted)}>widget</span>
              </div>

              <div :for={t <- @scoped_widget_tokens} class={[card(), "mb-2"]}>
                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div class="min-w-0">
                    <span class="font-medium">{t["label"] || gettext("Unlabeled")}</span>
                  </div>
                  <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                    <button phx-click="widget_edit" phx-value-id={t["id"]} class={btn_ghost()}>
                      {if @edit_widget == t["id"], do: gettext("Cancel"), else: gettext("Edit look")}
                    </button>
                    <.link navigate={~p"/tokens?scope=#{@scope}"} class={btn_ghost()}>{gettext("Manage token")}</.link>
                  </div>
                </div>
                <.meta_list class="mt-4">
                  <:item label={gettext("Agent:")}>{t["agent"] || gettext("(default)")}</:item>
                  <:item label={gettext("Origin:")} mono>{t["allowed_origin"] || gettext("no origin set")}</:item>
                </.meta_list>
                <p class={hlp()}>{gettext("The agent and website address can't be changed. Create a new widget to use different ones.")}</p>

                <form :if={@edit_widget == t["id"]} phx-submit="widget_edit_save" class="mt-3 border-t border-zinc-800 pt-3">
                  <input type="hidden" name="widget_id" value={t["id"]} />
                  <.widget_appearance_fields prefix="widget_edit" values={t} />
                  <div class="mt-3 flex gap-2">
                    <button type="submit" class={btn()}>{gettext("Save look")}</button>
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
          <div :if={@adding == :widget} class="max-w-3xl">
            <form phx-submit="widget_add" class="space-y-4">
              <.form_section title={gettext("+ Add a widget")}>
              <div>
                <label class={lbl()}>{gettext("Label")} <span class="text-zinc-600">{gettext("(optional)")}</span></label>
                <input name="widget[label]" placeholder={gettext("My website widget")} class={fld()} />
              </div>
              <div>
                <label class={lbl()}>{gettext("Agent")}</label>
                <select name="widget[agent]" class={fld()}>
                  <option value="">{gettext("Choose an agent...")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                </select>
                <p class={hlp()}>{gettext("A widget talks to one agent, not a whole project.")}</p>
              </div>
              <div>
                <label class={lbl()}>{gettext("Allowed website")}</label>
                <input name="widget[allowed_origin]" placeholder="https://example.com" class={fld()} />
                <p class={hlp()}>{gettext("Your website's address, like https://example.com. Other websites can't use this widget.")}</p>
              </div>
              <div class="border-t border-zinc-800 pt-4">
                <div class="mb-1 text-sm font-medium text-zinc-300">{gettext("Appearance")}</div>
                <p class={hlp()}>{gettext("Optional. Empty fields use the values in the pasted code.")}</p>
                <div class="mt-3">
                  <.widget_appearance_fields prefix="widget" values={%{}} />
                </div>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Create widget")}</button>
                <button type="button" phx-click="add_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
              </.form_section>
            </form>
          </div>

          <%!-- EDIT A TELEGRAM BOT --%>
          <div :if={@edit_bot} class="max-w-3xl">
            <form phx-submit="bot_save" phx-change="bot_change" class="space-y-4">
              <.form_section title={gettext("Edit %{name}", name: Labels.connection(@edit_bot["name"], @edit_bot).text)}>
              <input type="hidden" name="name" value={@edit_bot["name"]} />
              <div>
                <label class={lbl()}>{gettext("Label")} <span class="text-zinc-600">{gettext("(optional)")}</span></label>
                <input name="label" value={@edit_bot["label"] || ""} maxlength="60" class={fld()} placeholder={gettext("Sales bot")} />
                <p class={hlp()}>{gettext("How this bot is shown in the dashboard. Its name stays the id.")}</p>
              </div>
              <div>
                <label class={lbl()}>{gettext("This bot talks to")}</label>
                <select name="agent" class={fld()}>
                  <option value="">{gettext("The default agent")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @edit_bot["agent"]}>{a}</option>
                </select>
              </div>
              <div>
                <label class={lbl()}>{gettext("While the agent is working")}</label>
                <select name="tool_progress" class={fld()}>
                  <option value="reaction" selected={(@edit_bot["tool_progress"] || "reaction") == "reaction"}>{gettext("React (default)")}</option>
                  <option value="verbose" selected={@edit_bot["tool_progress"] == "verbose"}>{gettext("Detailed")}</option>
                  <option value="ambient" selected={@edit_bot["tool_progress"] == "ambient"}>{gettext("Ambient")}</option>
                  <option value="off" selected={@edit_bot["tool_progress"] == "off"}>{gettext("Nothing")}</option>
                </select>
                <p class={hlp()}>{gettext("What the bot shows while the agent works. It disappears when the answer arrives.")}</p>
                <%!-- The per-option detail is a wall of text next to a select that already names all
                     four options, so it stays folded away until someone actually wants it. --%>
                <details class="mt-2">
                  <summary class="cursor-pointer text-sm text-zinc-400 hover:text-zinc-200">{gettext("What each option does")}</summary>
                  <div class="mt-2 space-y-1 text-sm text-zinc-400">
                    <p>
                      <span class="text-zinc-200">👀 {gettext("React")}</span> ({gettext("default")}): {gettext("Only a 👀 on your message while it works. The quietest option.")}
                    </p>
                    <p>
                      <span class="text-zinc-200">🛠️ {gettext("Detailed")}</span>: {gettext("A live list of every tool the agent uses and why.")}
                    </p>
                    <p>
                      <span class="text-zinc-200">💬 {gettext("Ambient")}</span>: {gettext("One line saying what kind of work it is doing, without tool names.")}
                    </p>
                    <p>
                      <span class="text-zinc-200">🚫 {gettext("Nothing")}</span>: {gettext("No status message, only Telegram's \"typing...\" indicator.")}
                    </p>
                  </div>
                </details>
              </div>
              <div>
                <label class="flex items-center gap-2">
                  <input type="checkbox" name="require_approval" value="true" checked={@edit_bot["require_approval"] == true} class={checkbox_cls()} />
                  <span class="text-base text-zinc-300">{gettext("Approve new people first")}</span>
                </label>
                <p class={hlp()}>{gettext("On: the bot ignores anyone not on the approved list. Off: it answers everyone.")}</p>

                <%!-- Nested right under the toggle they belong to, not a separate section - and
                     `type="button"` on every action so a click here never submits the form. --%>
                <div :if={@edit_bot["require_approval"] == true} class="mt-3 space-y-3">
                  <div class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
                    <div class="font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{gettext("Waiting for approval")}</div>
                    <p :if={pending_users(@edit_bot) == []} class="mt-1.5 text-sm text-zinc-600">{gettext("No one is waiting.")}</p>
                    <div :if={pending_users(@edit_bot) != []} class="mt-2 space-y-1.5">
                      <div
                        :for={u <- pending_users(@edit_bot)}
                        class="flex items-center justify-between gap-3 rounded-lg bg-zinc-900 px-3 py-2"
                      >
                        <div class="min-w-0">
                          <div class="text-sm text-zinc-200">
                            {u["name"]} <span class="font-mono text-xs text-zinc-500">{gettext("id %{id}", id: u["id"])}</span>
                          </div>
                          <div class="truncate text-xs text-zinc-500">{u["sample"]}</div>
                        </div>
                        <div class="flex shrink-0 flex-wrap gap-1.5">
                          <button
                            type="button"
                            phx-click="bot_approve_user"
                            phx-value-name={@edit_bot["name"]}
                            phx-value-id={u["id"]}
                            class={btn()}
                          >
                            {gettext("Add")}
                          </button>
                          <button
                            type="button"
                            phx-click="bot_dismiss_user"
                            phx-value-name={@edit_bot["name"]}
                            phx-value-id={u["id"]}
                            class={btn_ghost()}
                          >
                            {gettext("Ignore")}
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
                    <div class="font-mono text-[11px] font-normal uppercase tracking-[.18em] text-zinc-600">{gettext("Allowed users")}</div>
                    <p :if={allowed_users(@edit_bot) == []} class="mt-1.5 text-sm text-zinc-600">{gettext("No one has been approved yet.")}</p>
                    <div :if={allowed_users(@edit_bot) != []} class="mt-2 space-y-1.5">
                      <div
                        :for={u <- allowed_users(@edit_bot)}
                        class="flex items-center justify-between gap-3 rounded-lg bg-zinc-900 px-3 py-2"
                      >
                        <div class="text-sm text-zinc-200">
                          <span :if={u["name"]}>{u["name"]}</span>
                          <span :if={!u["name"]} class="text-zinc-500">{gettext("(no name saved)")}</span>
                          <span class="font-mono text-xs text-zinc-500">{gettext("id %{id}", id: u["id"])}</span>
                        </div>
                        <button
                          type="button"
                          phx-click="bot_revoke_user"
                          phx-value-name={@edit_bot["name"]}
                          phx-value-id={u["id"]}
                          data-confirm={gettext("Remove this person's access? They'll go back to being blocked.")}
                          class="rounded-lg border border-red-900/60 bg-red-950/40 px-3 py-1.5 text-sm text-red-300 transition hover:border-red-700 hover:bg-red-900/40"
                        >
                          {gettext("Revoke")}
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              <div>
                <label class={lbl()}>{gettext("Who can train this bot")}</label>
                <.trainers_picker
                  id="bot-trainers"
                  field="trainers"
                  value={@bot_trainers}
                  people={@bot_people}
                  inherit_label={gettext("Default: everyone who talks to it")}
                  rename_form="bot-rename-person"
                  renaming={@renaming_person}
                />
                <p class={hlp()}>
                  {gettext("Who the bot learns from, and who may run its operator commands. Pick from the people who have written to it, or add a Telegram user id.")}
                </p>
              </div>
              <div>
                <label class={lbl()}>{gettext("Bot token")} <span class="text-zinc-600">{gettext("(leave blank to keep the current key)")}</span></label>
                <input name="token" placeholder={"${TELEGRAM_BOT_TOKEN}  " <> gettext("(or paste a new key)")} class={fld()} />
                <p class={hlp()}>{gettext("Tip: write a reference like ${MY_BOT_TOKEN} so the key stays out of the settings file.")}</p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Save")}</button>
                <button type="button" phx-click="bot_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
              </.form_section>
            </form>
            <%!-- Outside the bot form on purpose: a person's inline rename submits here. --%>
            <.rename_form id="bot-rename-person" target={nil} />
          </div>

          <%!-- ADD A TELEGRAM BOT --%>
          <div :if={@adding == :bot} class="max-w-3xl">
            <.form for={@form} phx-submit="bot_add" class="space-y-4">
              <.form_section title={gettext("+ Add a bot")}>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("sales")} />
              <div>
                <.input field={@form[:token]} label={gettext("Bot token")} placeholder={"123456:ABC...  " <> gettext("or") <> "  ${SALES_BOT_TOKEN}"} />
                <p class={hlp()}>{gettext("Get it from @BotFather. Tip: write it as an environment variable like ${MY_BOT_TOKEN} to keep it out of the settings file.")}</p>
                <%!-- tool_progress and require_approval are edit-only fields, so say here what a
                     brand-new bot will do until someone goes and changes them. --%>
                <p class={hlp()}>{gettext("The bot shows 👀 while working and answers everyone. You can change both under Edit.")}</p>
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
              </.form_section>
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
    case color_error(blank(p["color"])) do
      nil -> create_widget(p, socket)
      msg -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("widget_dismiss", _p, socket), do: {:noreply, assign(socket, widget_raw: nil)}

  def handle_event("widget_edit", %{"id" => id}, socket) do
    next = if socket.assigns.edit_widget == id, do: nil, else: id
    {:noreply, assign(socket, edit_widget: next)}
  end

  def handle_event("widget_edit_save", %{"widget_id" => id, "widget_edit" => p}, socket) do
    case color_error(blank(p["color"])) do
      nil -> save_widget_appearance(id, p, socket)
      msg -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  # Open a webhook channel's form inside the shared component (which lives in this page).
  def handle_event("add_channel", %{"name" => name}, socket) do
    send_update(PepeWeb.ConnectionsComponent, id: "native-channels", open: name)
    {:noreply, assign(socket, adding_channel: true)}
  end

  # The header's back button for a webhook form: the form lives in the component, so ask it
  # to close, same as its own Cancel button does.
  def handle_event("channel_cancel", _p, socket) do
    send_update(PepeWeb.ConnectionsComponent, id: "native-channels", close: true)
    {:noreply, assign(socket, adding_channel: false)}
  end

  def handle_event("bot_add", %{"bot" => p}, socket) do
    cs =
      p
      |> bot_changeset()
      |> then(fn cs ->
        # Two bots on one token would 409 against each other on getUpdates.
        if token_taken?(p["token"], nil),
          do: Changeset.add_error(cs, :token, gettext("This key is already used by another bot")),
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
    text = Labels.connection(name).text
    Config.delete_telegram_bot(name)
    Pepe.SeenChannels.delete_connection(name)
    Pepe.SeenPeople.delete_connection(name)
    reload_gateways()
    {:noreply, socket |> assign(bots: Config.telegram_bots()) |> put_flash(:info, gettext("Bot %{name} removed.", name: text))}
  end

  def handle_event("restart_gateway", _p, socket) do
    Pepe.Gateways.Supervisor.restart_telegram()
    {:noreply, put_flash(socket, :info, gettext("Telegram gateway restarted."))}
  end

  def handle_event("bot_edit", %{"name" => name}, socket) do
    bot = Config.telegram_bot(name)

    {:noreply,
     assign(socket,
       edit_bot: bot,
       adding: nil,
       bot_trainers: TrainersPicker.form_value(bot && bot["trainers"]),
       bot_people: TrainersPicker.people(name)
     )}
  end

  # The form holds the picker's state between changes, so switching its mode shows the people.
  def handle_event("bot_change", %{"trainers" => value}, socket), do: {:noreply, assign(socket, bot_trainers: value)}
  def handle_event("bot_change", _params, socket), do: {:noreply, socket}

  def handle_event("bot_rename", %{"name" => name}, socket), do: {:noreply, assign(socket, renaming_bot: name)}

  def handle_event("bot_save_label", %{"name" => name, "label" => label}, socket),
    do: {:noreply, socket |> put_bot_label(name, label) |> assign(renaming_bot: nil)}

  def handle_event("bot_clear_label", %{"name" => name}, socket),
    do: {:noreply, socket |> put_bot_label(name, nil) |> assign(renaming_bot: nil)}

  # The people's inline rename inside the bot form's picker (see PepeWeb.TrainersPicker).
  def handle_event(event, params, socket) when event in ["rename_person", "save_person_label", "clear_person_label"] do
    name = socket.assigns.edit_bot && socket.assigns.edit_bot["name"]
    socket = TrainersPicker.person_event(event, params, socket, name)
    {:noreply, assign(socket, bot_people: (name && TrainersPicker.people(name)) || [])}
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

  def handle_event("bot_revoke_user", %{"name" => name, "id" => id}, socket) do
    Config.revoke_telegram_user(name, String.to_integer(id))
    reload_gateways()

    {:noreply,
     socket
     |> assign(bots: Config.telegram_bots(), edit_bot: Config.telegram_bot(name))
     |> put_flash(:info, gettext("Access revoked. They're blocked again."))}
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
        |> put_or_delete("label", Labels.clean(params["label"]))
        |> put_or_delete("trainers", telegram_trainers(params["trainers"]))
        |> put_or_delete("tool_progress", blank(params["tool_progress"]))
        |> Map.put("require_approval", params["require_approval"] == "true")
        |> maybe_put_token(new_token)

      save_bot(name, bot)
      reload_gateways()

      {:noreply,
       socket
       |> assign(bots: Config.telegram_bots(), edit_bot: nil)
       |> put_flash(:info, gettext("Bot %{name} saved.", name: Labels.connection(name, bot).text))}
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

  defp create_widget(p, socket) do
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

  defp save_widget_appearance(id, p, socket) do
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
        {:noreply, put_flash(socket, :error, gettext("Couldn't save. The widget may have been removed."))}
    end
  end

  # Does another bot (any but `exclude_name`) already resolve to this token? Compares
  # interpolated values so two ${ENV_VAR} refs to the same secret are caught too.
  # Telegram user ids are integers in the config (what `--trainers` and the approval list write),
  # while the picker, like every recorded person, carries them as strings.
  defp telegram_trainers(value) do
    case TrainersPicker.to_list(value) do
      nil -> nil
      list -> Enum.flat_map(list, &telegram_id/1)
    end
  end

  defp telegram_id("*"), do: ["*"]

  defp telegram_id(id) do
    case Integer.parse(id) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp put_bot_label(socket, name, label) do
    case Config.telegram_bot(name) do
      nil -> socket
      bot -> save_bot(name, bot |> Map.delete("name") |> put_or_delete("label", Labels.clean(label)))
    end

    assign(socket, bots: Config.telegram_bots())
  end

  defp maybe_put_token(bot, nil), do: bot
  defp maybe_put_token(bot, token), do: Map.put(bot, "bot_token", token)

  # Users this bot blocked (deny-by-default under require_approval) that are waiting to be let in.
  defp pending_users(%{"name" => name}), do: Config.telegram_pending(name)
  defp pending_users(_), do: []

  # Users already approved for this bot, with a name when one was captured at approval time.
  defp allowed_users(%{"name" => name}), do: Config.telegram_allowed(name)
  defp allowed_users(_), do: []

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
