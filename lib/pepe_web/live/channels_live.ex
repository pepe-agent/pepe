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
       companies: Config.companies(),
       new_company: false,
       bots: Config.telegram_bots(),
       edit_bot: nil,
       adding: nil,
       adding_channel: false,
       form: nil,
       native_channels: native_channel_cards()
     )}
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

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="bots" scope={@scope} companies={@companies} new_company={@new_company} />
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
                    <button :if={b["name"] != "default"} phx-click="bot_remove" phx-value-name={b["name"]}
                      data-confirm={gettext("Remove bot %{name}?", name: b["name"])} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
                  </div>
                </div>
                <div class="mt-1 text-sm text-zinc-400">{gettext("Agent:")} {b["agent"] || gettext("(default)")}</div>
                <div class="text-sm text-zinc-500">{gettext("Token:")} {token_hint(b["bot_token"])}</div>
              </div>
            </div>

            <%!-- Webhook groups (only those with a connection) or the open connection form --%>
            <.live_component
              module={PepeWeb.ConnectionsComponent}
              id="native-channels"
              providers={@native_channels}
              scope={@scope}
              companies={@companies}
              show_picker={false}
            />

            <%!-- One picker for every channel type: Telegram plus each webhook provider --%>
            <div :if={not @adding_channel} class="border-t border-zinc-800 pt-5">
              <div class="mb-2 text-sm font-medium text-zinc-400">{gettext("Add a channel")}</div>
              <div class="flex flex-wrap gap-2">
                <button phx-click="add" phx-value-kind="bot" class={btn_ghost()}>{gettext("+ Telegram bot")}</button>
                <button :for={p <- @native_channels} phx-click="add_channel" phx-value-name={p.name} class={btn_ghost()}>
                  + {p.label}
                </button>
              </div>
              <p class="mt-2 text-sm text-zinc-500">
                {gettext("WhatsApp, Slack, Discord, Microsoft Teams and Google Chat connect over each platform's official webhook. Fill in the credentials, then register the Webhook URL shown in the provider.")}
              </p>
            </div>
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
                <label class={lbl()}>{gettext("Bot token")} <span class="text-zinc-600">{gettext("(leave blank to keep the current one)")}</span></label>
                <input name="token" placeholder={"${TELEGRAM_BOT_TOKEN}  " <> gettext("(or paste a new token)")} class={fld()} />
                <p class={hlp()}>{gettext("Tip: use an env-var reference like ${MY_BOT_TOKEN} to keep the secret out of the config file.")}</p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Save")}</button>
                <button type="button" phx-click="bot_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </form>
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
  def handle_event("add", %{"kind" => _kind}, socket) do
    {:noreply, assign(socket, adding: :bot, edit_bot: nil, form: bot_form(%{}))}
  end

  def handle_event("add_cancel", _p, socket), do: {:noreply, assign(socket, adding: nil)}

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

  def handle_event("bot_save", %{"name" => name} = params, socket) do
    new_token = blank(params["token"])

    if new_token && token_taken?(new_token, name) do
      {:noreply, put_flash(socket, :error, gettext("That token is already used by another bot."))}
    else
      bot =
        (Config.telegram_bot(name) || %{})
        |> Map.delete("name")
        |> put_or_delete("agent", blank(params["agent"]))
        |> then(fn b -> if new_token, do: Map.put(b, "bot_token", new_token), else: b end)

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

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  @impl true
  def handle_info({:flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:channel_form, :closed}, socket), do: {:noreply, assign(socket, adding_channel: false)}

  # Does another bot (any but `exclude_name`) already resolve to this token? Compares
  # interpolated values so two ${ENV_VAR} refs to the same secret are caught too.
  defp token_taken?(token, exclude_name) do
    want = Config.interpolate(token) || token

    Config.telegram_bots()
    |> Enum.reject(&(&1["name"] == exclude_name))
    |> Enum.any?(fn b -> (Config.interpolate(b["bot_token"]) || b["bot_token"]) == want end)
  end
end
