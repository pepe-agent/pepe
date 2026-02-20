defmodule PepeWeb.ScheduledLive do
  @moduledoc "Scheduled tasks (cron) section: recurring agent jobs."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Scheduled",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       crons: Config.crons(),
       cron_custom: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="cron" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🕒"
          title={gettext("Scheduled tasks")}
          desc={gettext("Recurring jobs: an agent runs a fixed instruction on a schedule and reports the result. They fire while the server is running.")}
        />
        <div class="flex-1 space-y-4 overflow-y-auto p-6">
          <div :for={c <- scoped_by_agent(@crons, @scope, & &1.agent)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{c.name}</span>
                <span class={["ml-2 rounded px-1.5 text-xs", c.enabled && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                  {(c.enabled && gettext("enabled")) || gettext("disabled")}
                </span>
              </div>
              <div class="flex shrink-0 gap-1 text-xs">
                <button phx-click="cron_run" phx-value-id={c.id} class={btn_ghost()}>{gettext("Run now")}</button>
                <button phx-click="cron_toggle" phx-value-id={c.id} class={btn_ghost()}>{(c.enabled && gettext("Disable")) || gettext("Enable")}</button>
                <button phx-click="cron_remove" phx-value-id={c.id} data-confirm={gettext("Remove scheduled task %{name}?", name: c.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-xs text-zinc-400"><code>{c.schedule}</code> · {c.timezone} · {gettext("next")} {cron_next(c)}</div>
            <div class="text-xs text-zinc-500">{c.agent}{model_suffix(c.model)} · → {deliver_label(c.deliver)}</div>
            <details class="mt-1">
              <summary class="cursor-pointer text-xs text-zinc-500">{gettext("prompt & last runs")}</summary>
              <pre class="mt-1 whitespace-pre-wrap rounded bg-zinc-900 p-2 text-xs text-zinc-300">{c.prompt}</pre>
              <div :for={e <- cron_history(c.id)} class="mt-1 text-xs text-zinc-400">
                {(e["ok"] && "✅") || "⚠️"} {learn_date(e["at"])} · {e["source"]}
                <span class="text-zinc-500">— {String.slice(to_string(e["output"]), 0, 120)}</span>
              </div>
            </details>
          </div>
          <p :if={@crons == []} class="text-sm text-zinc-500">{gettext("No scheduled tasks yet — create one below.")}</p>

          <form phx-submit="cron_create" class="space-y-4 rounded-xl border border-blue-900/60 bg-blue-950/10 p-5">
            <div class="text-sm font-medium">{gettext("+ New scheduled task")}</div>
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input name="name" placeholder={gettext("Daily XML check")} class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("What to do")} <span class="text-zinc-600">{gettext("— runs fresh each time, no chat memory")}</span></label>
              <textarea name="prompt" rows="3" placeholder={gettext("Check the 06:00 XML load and report anything off.")} class={fld()}></textarea>
            </div>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class={lbl()}>{gettext("When")} <span class="text-zinc-600">{gettext("(cron)")}</span></label>
                <select name="schedule" phx-change="cron_schedule" class={fld()}>
                  <option value="0 8 * * *">{gettext("Every day at 08:00")}</option>
                  <option value="0 * * * *">{gettext("Every hour")}</option>
                  <option value="*/15 * * * *">{gettext("Every 15 minutes")}</option>
                  <option value="0 9 * * 1">{gettext("Every Monday 09:00")}</option>
                  <option value="0 0 1 * *">{gettext("First of the month")}</option>
                  <option value="custom" selected={@cron_custom}>{gettext("Custom…")}</option>
                </select>
                <input :if={@cron_custom} name="schedule_custom" placeholder="*/5 * * * *" class={[fld(), "mt-2 font-mono"]} />
                <p :if={@cron_custom} class={hlp()}>
                  {gettext("5 fields: minute hour day month weekday. E.g. \"30 9 * * 1-5\" = 09:30 on weekdays. Invalid expressions are rejected.")}
                </p>
              </div>
              <div>
                <label class={lbl()}>{gettext("Timezone")}</label>
                <select name="timezone" class={fld()}>
                  <option :for={tz <- timezone_options()} value={tz}>{tz}</option>
                </select>
              </div>
            </div>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class={lbl()}>{gettext("Agent")}</label>
                <select name="agent" class={fld()}>
                  <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                </select>
              </div>
              <div>
                <label class={lbl()}>{gettext("Model")}</label>
                <select name="model" class={fld()}>
                  <option value="">{gettext("agent's default")}</option>
                  <option :for={m <- model_names()} value={m}>{m}</option>
                </select>
              </div>
            </div>
            <div>
              <label class={lbl()}>{gettext("Report the result to")}</label>
              <select name="deliver" class={fld()}>
                <option value="none">{gettext("Nowhere (just keep the run history)")}</option>
                <option value="log">{gettext("The app log")}</option>
                <option :for={t <- telegram_targets()} value={t}>{deliver_label(t)}</option>
              </select>
              <input :if={telegram_targets() == []} name="deliver_chat"
                placeholder={gettext("No Telegram chats yet — paste a chat id (find it with /whoami)")} class={[fld(), "mt-2"]} />
            </div>
            <button type="submit" class={btn()}>{gettext("Create task")}</button>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("cron_run", %{"id" => id}, socket) do
    case Config.get_cron(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found."))}

      cron ->
        Task.start(fn -> Pepe.Cron.run(cron, :manual) end)
        {:noreply, put_flash(socket, :info, gettext("Running “%{name}” now…", name: cron.name))}
    end
  end

  def handle_event("cron_toggle", %{"id" => id}, socket) do
    case Config.get_cron(id) do
      nil ->
        {:noreply, socket}

      cron ->
        Config.put_cron(%{cron | enabled: !cron.enabled})
        {:noreply, assign(socket, crons: Config.crons())}
    end
  end

  def handle_event("cron_remove", %{"id" => id}, socket) do
    Config.delete_cron(id)
    Pepe.Cron.Log.delete(id)
    {:noreply, assign(socket, crons: Config.crons())}
  end

  def handle_event("cron_schedule", %{"schedule" => v}, socket) do
    {:noreply, assign(socket, cron_custom: v == "custom")}
  end

  def handle_event("cron_create", params, socket) do
    name = String.trim(params["name"] || "")
    prompt = String.trim(params["prompt"] || "")

    schedule =
      if params["schedule"] == "custom",
        do: String.trim(params["schedule_custom"] || ""),
        else: params["schedule"]

    cond do
      name == "" or prompt == "" ->
        {:noreply, put_flash(socket, :error, gettext("Name and what-to-do are required."))}

      match?({:error, _}, Pepe.Cron.parse(schedule)) ->
        {:error, msg} = Pepe.Cron.parse(schedule)
        {:noreply, put_flash(socket, :error, gettext("Invalid schedule: %{msg}", msg: msg))}

      true ->
        Config.put_cron(%Pepe.Config.Cron{
          id: new_cron_id(name),
          name: name,
          agent: blank(params["agent"]) || Config.default_agent_name(),
          prompt: prompt,
          schedule: schedule,
          timezone: blank(params["timezone"]) || Config.default_timezone(),
          model: blank(params["model"]),
          deliver: deliver_from(params),
          enabled: true
        })

        {:noreply,
         socket |> assign(crons: Config.crons()) |> put_flash(:info, gettext("Task created."))}
    end
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/cron")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}
end
