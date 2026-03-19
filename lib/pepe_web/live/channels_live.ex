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
       form: nil,
       whatsapp: wa_list()
     )}
  end

  # WhatsApp connections (webhook-based), newest config wins.
  defp wa_list do
    Config.webhooks() |> Enum.filter(fn {_slug, e} -> e["provider"] == "whatsapp" end)
  end

  defp bot_changeset(attrs) do
    {%{}, %{name: :string, token: :string, agent: :string}}
    |> Changeset.cast(attrs, [:name, :token, :agent])
    |> Changeset.validate_required([:name, :token])
    |> Changeset.validate_exclusion(:name, ["default"], message: gettext("pick another name"))
  end

  defp wa_changeset(attrs) do
    fields = [:slug, :mode, :agent, :phone_number_id, :verify_token, :access_token, :app_secret]

    {%{}, Map.new(fields, &{&1, :string})}
    |> Changeset.cast(attrs, fields)
    |> Changeset.validate_required([:slug, :agent, :phone_number_id])
  end

  defp bot_form(attrs), do: to_form(bot_changeset(attrs), as: :bot)
  defp wa_form(attrs), do: to_form(wa_changeset(attrs), as: :wa)

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
          desc={gettext("Connect your agents to messaging channels so people can chat with them: Telegram bots and WhatsApp (Meta Cloud API) numbers, each bound to an agent.")}
        >
          <button :if={!@edit_bot and @adding == nil} phx-click="add" phx-value-kind="bot" class={btn()}>{gettext("+ Telegram bot")}</button>
          <button :if={!@edit_bot and @adding == nil} phx-click="add" phx-value-kind="wa" class={btn_ghost()}>{gettext("+ WhatsApp")}</button>
          <button :if={!@edit_bot and @adding == nil} phx-click="restart_gateway"
            data-confirm={gettext("Restart the Telegram gateway now?")} class={btn_ghost()} title={gettext("Recovery: respawn the pollers if the gateway seems stuck")}>
            ↻ {gettext("Restart gateway")}
          </button>
          <button :if={@edit_bot} phx-click="bot_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
          <button :if={@adding != nil} phx-click="add_cancel" class={btn_ghost()}>&larr; {gettext("Back to channels")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-6">
          <%!-- LIST --%>
          <div :if={!@edit_bot and @adding == nil} class="space-y-4">
            <div :for={b <- scoped_by_agent(@bots, @scope, & &1["agent"])} class={card()}>
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
              <div class="mt-1 text-sm text-zinc-400">{gettext("agent:")} {b["agent"] || gettext("(default)")}</div>
              <div class="text-sm text-zinc-500">{gettext("token:")} {token_hint(b["bot_token"])}</div>
            </div>
            <p :if={@bots == []} class="text-[15px] text-zinc-500">
              {gettext("No bots yet. The default bot is set via")} <code>mix pepe gateway telegram setup</code>.
            </p>

            <div class="border-t border-zinc-800 pt-5">
              <div class="mb-2 text-[15px] font-medium">{gettext("WhatsApp (Meta Cloud API)")}</div>
              <div :for={{slug, e} <- @whatsapp} class={[card(), "mb-2"]}>
                <div class="flex items-center justify-between gap-2">
                  <div class="min-w-0">
                    <span class="font-medium">{slug}</span>
                    <span class={["ml-2 rounded px-1.5 text-sm", (e["mode"] == "admin" && "bg-indigo-700") || "bg-zinc-700 text-zinc-300"]}>
                      {e["mode"] || "support"}
                    </span>
                  </div>
                  <button phx-click="wa_remove" phx-value-slug={slug}
                    data-confirm={gettext("Remove WhatsApp connection %{slug}?", slug: slug)}
                    class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
                </div>
                <div class="mt-1 text-sm text-zinc-400">{gettext("agent:")} {e["agent"] || gettext("(default)")}</div>
                <div class="text-sm text-zinc-500">
                  {gettext("Callback URL")}: <code>/webhooks/{e["company"] || "root"}/whatsapp/{slug}</code>
                  <span class="text-zinc-600">({gettext("prefix with your public host")})</span>
                </div>
              </div>
              <p :if={@whatsapp == []} class="text-sm text-zinc-500">{gettext("No WhatsApp numbers connected yet.")}</p>
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
                  <option value="">{gettext("the default agent")}</option>
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
                  <option value="">{gettext("the default agent")}</option>
                  <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                </select>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Add bot")}</button>
                <button type="button" phx-click="add_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>

          <%!-- CONNECT A WHATSAPP NUMBER --%>
          <div :if={@adding == :wa} class="max-w-2xl">
            <.form for={@form} phx-submit="wa_add" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("+ Connect a WhatsApp number")}</div>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <div class="grid grid-cols-2 gap-3">
                <.input field={@form[:slug]} label={gettext("Slug (URL id)")} placeholder="suporte" />
                <div>
                  <label class={lbl()}>{gettext("Mode")}</label>
                  <select name="wa[mode]" class={fld()}>
                    <option value="support">{gettext("support (customer-facing)")}</option>
                    <option value="admin">{gettext("admin (yours)")}</option>
                  </select>
                </div>
              </div>
              <div>
                <.input field={@form[:agent]} type="select" label={gettext("This connection talks to")}
                  options={scoped_agent_names(@scope)} prompt={gettext("choose an agent")} />
                <p class={hlp()}>{gettext("The agent's company scopes the connection automatically.")}</p>
              </div>
              <div class="grid grid-cols-2 gap-3">
                <.input field={@form[:phone_number_id]} label={gettext("Phone number ID")} placeholder="123456789" />
                <.input field={@form[:verify_token]} label={gettext("Verify token")} placeholder={gettext("(defaults to the slug)")} />
              </div>
              <div class="grid grid-cols-2 gap-3">
                <.input field={@form[:access_token]} label={gettext("Access token")} class={[fld(), "font-mono"]} placeholder="${WA_TOKEN_SUPORTE}" />
                <.input field={@form[:app_secret]} label={gettext("App secret")} class={[fld(), "font-mono"]} placeholder="${WA_APP_SECRET_SUPORTE}" />
              </div>
              <p class={hlp()}>
                {gettext("Write tokens as ${ENV_VAR} to keep secrets out of the config file. Leave blank to auto-name them from the slug.")}
              </p>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Connect")}</button>
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
  def handle_event("add", %{"kind" => kind}, socket) do
    {kind, form} = if kind == "wa", do: {:wa, wa_form(%{})}, else: {:bot, bot_form(%{})}
    {:noreply, assign(socket, adding: kind, edit_bot: nil, form: form)}
  end

  def handle_event("add_cancel", _p, socket), do: {:noreply, assign(socket, adding: nil)}

  def handle_event("bot_add", %{"bot" => p}, socket) do
    cs = bot_changeset(p)

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

  def handle_event("wa_add", %{"wa" => p}, socket) do
    slug = String.trim(p["slug"] || "")

    cs =
      p
      |> wa_changeset()
      |> then(fn cs ->
        if slug != "" and Config.webhook_exists?(slug),
          do: Changeset.add_error(cs, :slug, gettext("already in use")),
          else: cs
      end)

    if cs.valid? do
      agent = blank(p["agent"])
      mode = if p["mode"] == "admin", do: "admin", else: "support"
      support? = mode == "support"
      up = String.upcase(slug)

      entry =
        reject_nil(%{
          "provider" => "whatsapp",
          "company" => Pepe.Company.of(agent),
          "agent" => agent,
          "mode" => mode,
          "commands" => mode == "admin",
          "trainers" => if(support?, do: [], else: nil),
          "ephemeral" => support?,
          "config" =>
            reject_nil(%{
              "phone_number_id" => blank(p["phone_number_id"]),
              "access_token" => blank(p["access_token"]) || "${WA_TOKEN_#{up}}",
              "app_secret" => blank(p["app_secret"]) || "${WA_APP_SECRET_#{up}}",
              "verify_token" => blank(p["verify_token"]) || slug
            })
        })

      Config.put_webhook(slug, entry)

      {:noreply,
       socket
       |> assign(whatsapp: wa_list(), adding: nil)
       |> put_flash(
         :info,
         gettext("WhatsApp %{slug} connected. Register its Callback URL in Meta.", slug: slug)
       )}
    else
      {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :wa))}
    end
  end

  def handle_event("wa_remove", %{"slug" => slug}, socket) do
    Config.delete_webhook(slug)
    {:noreply, assign(socket, whatsapp: wa_list())}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/bots")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}
end
