defmodule PepeWeb.ChannelsLive do
  @moduledoc "Channels section: connect agents to messaging channels (Telegram today)."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

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
       edit_bot: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="bots" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="📡"
          title={gettext("Channels")}
          desc={gettext("Connect your agents to messaging channels so people can chat with them. Telegram is available now — Slack and others are coming.")}
        />
        <div class="flex-1 space-y-4 overflow-y-auto p-6">
          <div :for={b <- scoped_by_agent(@bots, @scope, & &1["agent"])} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{b["name"]}</span>
                <span class={["ml-2 rounded px-1.5 text-xs", bot_active?(b) && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                  {(bot_active?(b) && gettext("active")) || gettext("inactive")}
                </span>
              </div>
              <div class="flex shrink-0 gap-1 text-xs">
                <button phx-click="bot_edit" phx-value-name={b["name"]} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={b["name"] != "default"} phx-click="bot_remove" phx-value-name={b["name"]}
                  data-confirm={gettext("Remove bot %{name}?", name: b["name"])} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-xs text-zinc-400">{gettext("agent:")} {b["agent"] || gettext("(default)")}</div>
            <div class="text-xs text-zinc-500">{gettext("token:")} {token_hint(b["bot_token"])}</div>
          </div>
          <p :if={@bots == []} class="text-sm text-zinc-500">
            {gettext("No bots yet. The default bot is set via")} <code>mix pepe gateway telegram setup</code>.
          </p>

          <form :if={@edit_bot} phx-submit="bot_save" class="space-y-4 rounded-xl border border-blue-900/60 bg-blue-950/10 p-5">
            <div class="text-sm font-medium">{gettext("Edit %{name}", name: @edit_bot["name"])}</div>
            <input type="hidden" name="name" value={@edit_bot["name"]} />
            <div>
              <label class={lbl()}>{gettext("This bot talks to")}</label>
              <select name="agent" class={fld()}>
                <option value="">{gettext("the default agent")}</option>
                <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @edit_bot["agent"]}>{a}</option>
              </select>
            </div>
            <div>
              <label class={lbl()}>{gettext("Bot token")} <span class="text-zinc-600">{gettext("— leave blank to keep the current one")}</span></label>
              <input name="token" placeholder={"${TELEGRAM_BOT_TOKEN}  " <> gettext("(or paste a new token)")} class={fld()} />
              <p class={hlp()}>{gettext("Tip: use an env-var reference like ${MY_BOT_TOKEN} to keep the secret out of the config file.")}</p>
            </div>
            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="bot_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>

          <form phx-submit="bot_add" class="space-y-4 rounded-xl border border-blue-900/60 bg-blue-950/10 p-5">
            <div class="text-sm font-medium">{gettext("+ Add a bot")}</div>
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input name="name" placeholder={gettext("sales")} class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("Bot token")} <span class="text-zinc-600">{gettext("— from @BotFather")}</span></label>
              <input name="token" placeholder="123456:ABC…  or  ${SALES_BOT_TOKEN}" class={fld()} />
              <p class={hlp()}>{gettext("Tip: use an env-var reference to keep the token out of the config file.")}</p>
            </div>
            <div>
              <label class={lbl()}>{gettext("This bot talks to")}</label>
              <select name="agent" class={fld()}>
                <option value="">{gettext("the default agent")}</option>
                <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
              </select>
            </div>
            <button type="submit" class={btn()}>{gettext("Add bot")}</button>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("bot_add", %{"name" => name, "token" => token} = params, socket) do
    name = String.trim(name)

    cond do
      name in ["", "default"] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a name other than \"default\"."))}

      blank(token) == nil ->
        {:noreply, put_flash(socket, :error, gettext("A bot token is required."))}

      true ->
        Config.put_telegram_bot(
          name,
          reject_nil(%{"bot_token" => token, "agent" => blank(params["agent"])})
        )

        reload_gateways()

        {:noreply,
         socket
         |> assign(bots: Config.telegram_bots())
         |> put_flash(:info, gettext("Bot %{name} added.", name: name))}
    end
  end

  def handle_event("bot_remove", %{"name" => name}, socket) do
    Config.delete_telegram_bot(name)
    reload_gateways()
    {:noreply, assign(socket, bots: Config.telegram_bots())}
  end

  def handle_event("bot_edit", %{"name" => name}, socket) do
    {:noreply, assign(socket, edit_bot: Config.telegram_bot(name))}
  end

  def handle_event("bot_cancel", _p, socket), do: {:noreply, assign(socket, edit_bot: nil)}

  def handle_event("bot_save", %{"name" => name} = params, socket) do
    bot =
      (Config.telegram_bot(name) || %{})
      |> Map.delete("name")
      |> put_or_delete("agent", blank(params["agent"]))
      |> then(fn b -> if t = blank(params["token"]), do: Map.put(b, "bot_token", t), else: b end)

    save_bot(name, bot)
    reload_gateways()

    {:noreply,
     socket
     |> assign(bots: Config.telegram_bots(), edit_bot: nil)
     |> put_flash(:info, gettext("Bot %{name} saved.", name: name))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/bots")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}
end
