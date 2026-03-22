defmodule PepeWeb.ScheduledLive do
  @moduledoc "Scheduled tasks (cron) section: recurring agent jobs."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData
  import PepeWeb.AiFill, only: [ai_star: 1, ai_popup: 1]

  alias Ecto.Changeset
  alias Pepe.Config
  alias PepeWeb.AiFill

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

    {:ok,
     assign(socket,
       page_title: "Pepe · Scheduled",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       crons: Config.crons(),
       cron_custom: false,
       ai: AiFill.init(),
       running: MapSet.new(),
       creating: false,
       viewing_log: nil,
       edit_cron: nil,
       form: cron_form(%{})
     )}
  end

  @impl true
  def handle_async({:ai_fill, field}, {:ok, {:ok, value}}, socket) do
    {:noreply, assign(socket, ai: AiFill.put(socket.assigns.ai, field, value))}
  end

  def handle_async({:ai_fill, _field}, _result, socket) do
    {:noreply,
     socket
     |> assign(ai: %{socket.assigns.ai | busy: false})
     |> put_flash(:error, gettext("AI couldn't produce a valid value. Try rephrasing."))}
  end

  @impl true
  def handle_info({:cron_run, :started, id}, socket),
    do: {:noreply, assign(socket, running: MapSet.put(socket.assigns.running, id))}

  def handle_info({:cron_run, :finished, id}, socket),
    do: {:noreply, assign(socket, running: MapSet.delete(socket.assigns.running, id), crons: Config.crons())}

  defp cron_changeset(attrs) do
    types = %{name: :string, prompt: :string, schedule: :string}

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:name, :prompt])
  end

  defp cron_form(attrs), do: to_form(cron_changeset(attrs), as: :cron)

  # The schedule of the cron being edited (or nil), for pre-selecting the preset option.
  defp cron_sched(nil), do: nil
  defp cron_sched(cron), do: cron.schedule

  # A preset schedule matches one of the dropdown options; anything else is "custom".
  @cron_presets ["0 8 * * *", "0 * * * *", "*/15 * * * *", "0 9 * * 1", "0 0 1 * *"]

  # Run log for the dedicated log view (full output, newest first) and the card summary.
  defp cron_log_entries(id), do: Pepe.Cron.Log.tail(id, 50)
  defp cron_last(id), do: List.first(Pepe.Cron.Log.tail(id, 1))
  defp cron_last_icon(id), do: (cron_last(id)["ok"] && "✅") || "⚠️"

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
        >
          <button :if={!@creating and !@viewing_log} phx-click="cron_new" class={btn()}>{gettext("+ New task")}</button>
          <button :if={@creating} phx-click="cron_cancel" class={btn_ghost()}>&larr; {gettext("Back to tasks")}</button>
          <button :if={@viewing_log} phx-click="cron_log_close" class={btn_ghost()}>&larr; {gettext("Back to tasks")}</button>
        </.view_header>

        <div :if={@creating} class="min-h-0 flex-1 overflow-y-auto p-6">
          <div class="max-w-2xl">
            <.form for={@form} phx-submit="cron_create" phx-change="cron_validate" class="space-y-4">
              <div class="text-lg font-semibold">
                {if @edit_cron, do: gettext("Edit %{name}", name: @edit_cron.name), else: gettext("+ New task")}
              </div>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("Daily XML check")} />
              <div>
                <.input field={@form[:prompt]} type="textarea" rows="3"
                  label={gettext("What to do")} placeholder={gettext("Check the 06:00 XML load and report anything off.")} />
                <p class={hlp()}>{gettext("(runs fresh each time, no chat memory)")}</p>
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class={lbl()}>{gettext("When")} <span class="text-zinc-600">{gettext("(cron)")}</span></label>
                  <select name="cron[schedule]" class={fld()}>
                    <option value="0 8 * * *" selected={cron_sched(@edit_cron) == "0 8 * * *"}>{gettext("Every day at 08:00")}</option>
                    <option value="0 * * * *" selected={cron_sched(@edit_cron) == "0 * * * *"}>{gettext("Every hour")}</option>
                    <option value="*/15 * * * *" selected={cron_sched(@edit_cron) == "*/15 * * * *"}>{gettext("Every 15 minutes")}</option>
                    <option value="0 9 * * 1" selected={cron_sched(@edit_cron) == "0 9 * * 1"}>{gettext("Every Monday 09:00")}</option>
                    <option value="0 0 1 * *" selected={cron_sched(@edit_cron) == "0 0 1 * *"}>{gettext("First of the month")}</option>
                    <option value="custom" selected={@cron_custom}>{gettext("Custom...")}</option>
                  </select>
                  <div :if={@cron_custom} class="mt-2 flex items-start gap-2">
                    <input name="cron[schedule_custom]"
                      value={AiFill.value(@ai, "cron[schedule_custom]", @edit_cron && @edit_cron.schedule)}
                      placeholder="*/5 * * * *" class={[fld(), "font-mono"]} />
                    <.ai_star field="cron[schedule_custom]" kind="cron" ai={@ai}
                      placeholder={gettext("e.g. every weekday at 9:30")} />
                  </div>
                  <p :if={se = @form.source.errors[:schedule]} class="mt-1.5 text-sm text-red-400">{elem(se, 0)}</p>
                  <p :if={@cron_custom} class={hlp()}>
                    {gettext("5 fields: minute hour day month weekday. E.g. \"30 9 * * 1-5\" = 09:30 on weekdays. Invalid expressions are rejected.")}
                  </p>
                </div>
                <div>
                  <label class={lbl()}>{gettext("Timezone")}</label>
                  <select name="cron[timezone]" class={fld()}>
                    <option :for={tz <- timezone_options()} value={tz} selected={@edit_cron && @edit_cron.timezone == tz}>{tz}</option>
                  </select>
                </div>
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class={lbl()}>{gettext("Agent")}</label>
                  <select name="cron[agent]" class={fld()}>
                    <option :for={a <- scoped_agent_names(@scope)} value={a} selected={@edit_cron && @edit_cron.agent == a}>{a}</option>
                  </select>
                </div>
                <div>
                  <label class={lbl()}>{gettext("Model")}</label>
                  <select name="cron[model]" class={fld()}>
                    <option value="" selected={@edit_cron && @edit_cron.model in [nil, ""]}>{gettext("agent's default")}</option>
                    <option :for={m <- model_names()} value={m} selected={@edit_cron && @edit_cron.model == m}>{m}</option>
                  </select>
                </div>
              </div>
              <div>
                <label class={lbl()}>{gettext("Report the result to")}</label>
                <select name="cron[deliver]" class={fld()}>
                  <option value="none" selected={@edit_cron && @edit_cron.deliver in ["none", nil, ""]}>{gettext("Nowhere (just keep the run history)")}</option>
                  <option value="log" selected={@edit_cron && @edit_cron.deliver == "log"}>{gettext("The app log")}</option>
                  <option :for={t <- telegram_targets()} value={t} selected={@edit_cron && @edit_cron.deliver == t}>{deliver_label(t)}</option>
                </select>
                <input :if={telegram_targets() == []} name="cron[deliver_chat]"
                  placeholder={gettext("No Telegram chats yet. Paste a chat id (find it with /whoami)")} class={[fld(), "mt-2"]} />
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{if @edit_cron, do: gettext("Save"), else: gettext("Create task")}</button>
                <button type="button" phx-click="cron_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
            <.ai_popup ai={@ai} models={model_names()} default_model={Config.default_model_name()} />
          </div>
        </div>

        <div :if={@viewing_log} class="min-h-0 flex-1 overflow-y-auto p-6">
          <% cron = Enum.find(@crons, &(&1.id == @viewing_log)) %>
          <div :if={cron} class="max-w-3xl">
            <div class="text-lg font-semibold">{cron.name}</div>
            <div class="mt-0.5 text-sm text-zinc-500"><code>{cron.schedule}</code> · {cron.timezone} · {cron.agent}{model_suffix(cron.model)}</div>

            <div class="mt-4">
              <div class="mb-1.5 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("Prompt")}</div>
              <pre class="whitespace-pre-wrap rounded-lg bg-zinc-900 p-3 text-sm text-zinc-300">{cron.prompt}</pre>
            </div>

            <div class="mt-5">
              <div class="mb-1.5 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("Run log")}</div>
              <p :if={cron_log_entries(@viewing_log) == []} class="text-[15px] text-zinc-500">{gettext("No runs yet.")}</p>
              <div :for={e <- cron_log_entries(@viewing_log)} class="mb-2 rounded-lg border border-zinc-800 p-3">
                <div class="flex items-center gap-2 text-sm">
                  <span>{(e["ok"] && "✅") || "⚠️"}</span>
                  <span class="text-zinc-300">{learn_date(e["at"])}</span>
                  <span class="text-zinc-500">· {e["source"]}</span>
                </div>
                <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-zinc-950/60 p-2.5 text-sm text-zinc-400">{e["output"]}</pre>
              </div>
            </div>
          </div>
        </div>

        <div :if={!@creating and !@viewing_log} class="flex-1 space-y-4 overflow-y-auto p-6">
          <div :for={c <- scoped_by_agent(@crons, @scope, & &1.agent)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{c.name}</span>
                <span class={["ml-2 rounded px-1.5 text-sm", c.enabled && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                  {(c.enabled && gettext("enabled")) || gettext("disabled")}
                </span>
                <span :if={MapSet.member?(@running, c.id)} class="ml-2 inline-flex items-center gap-1.5 align-middle text-sm font-medium text-orange-300">
                  <span class="relative flex h-2 w-2">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-orange-400 opacity-75"></span>
                    <span class="relative inline-flex h-2 w-2 rounded-full bg-orange-400"></span>
                  </span>
                  {gettext("running")}
                </span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <button phx-click="cron_run" phx-value-id={c.id} disabled={MapSet.member?(@running, c.id)}
                  class={[btn_ghost(), "disabled:opacity-50"]}>
                  {if MapSet.member?(@running, c.id), do: gettext("running..."), else: gettext("Run now")}
                </button>
                <button phx-click="cron_log" phx-value-id={c.id} class={btn_ghost()}>{gettext("Log")}</button>
                <button phx-click="cron_edit" phx-value-id={c.id} class={btn_ghost()}>{gettext("Edit")}</button>
                <button phx-click="cron_toggle" phx-value-id={c.id} class={btn_ghost()}>{(c.enabled && gettext("Disable")) || gettext("Enable")}</button>
                <button phx-click="cron_remove" phx-value-id={c.id} data-confirm={gettext("Remove scheduled task %{name}?", name: c.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400"><code>{c.schedule}</code> · {c.timezone} · {gettext("next")} {cron_next(c)}</div>
            <div class="text-sm text-zinc-500">{c.agent}{model_suffix(c.model)} · -> {deliver_label(c.deliver)}</div>
            <div :if={cron_last(c.id)} class="mt-1 text-sm text-zinc-500">
              {cron_last_icon(c.id)} {gettext("last run")} {learn_date(cron_last(c.id)["at"])} ·
              <button phx-click="cron_log" phx-value-id={c.id} class="text-orange-400 hover:text-orange-300">{gettext("see log")}</button>
            </div>
          </div>
          <p :if={@crons == []} class="text-[15px] text-zinc-500">{gettext("No scheduled tasks yet. Create one with “+ New task”.")}</p>
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
        # Fire and forget: the live "running" state is driven by the PubSub lifecycle
        # events `Pepe.Cron.run` broadcasts, so a scheduler-fired run lights up too.
        Task.start(fn -> Pepe.Cron.run(cron, :manual) end)
        {:noreply, socket}
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
    viewing = if socket.assigns.viewing_log == id, do: nil, else: socket.assigns.viewing_log
    {:noreply, assign(socket, crons: Config.crons(), viewing_log: viewing)}
  end

  def handle_event("cron_new", _p, socket),
    do: {:noreply, assign(socket, creating: true, viewing_log: nil, edit_cron: nil, form: cron_form(%{}), cron_custom: false)}

  def handle_event("cron_log", %{"id" => id}, socket),
    do: {:noreply, assign(socket, viewing_log: id, creating: false)}

  def handle_event("cron_log_close", _p, socket),
    do: {:noreply, assign(socket, viewing_log: nil)}

  def handle_event("cron_edit", %{"id" => id}, socket) do
    case Config.get_cron(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Task not found."))}

      cron ->
        {:noreply,
         assign(socket,
           creating: true,
           viewing_log: nil,
           edit_cron: cron,
           form: cron_form(%{"name" => cron.name, "prompt" => cron.prompt}),
           cron_custom: cron.schedule not in @cron_presets
         )}
    end
  end

  def handle_event("cron_cancel", _p, socket),
    do: {:noreply, assign(socket, creating: false, edit_cron: nil)}

  def handle_event("cron_validate", %{"cron" => p}, socket) do
    cs = %{cron_changeset(p) | action: :validate}

    {:noreply, assign(socket, form: to_form(cs, as: :cron), cron_custom: p["schedule"] == "custom")}
  end

  def handle_event("cron_create", %{"cron" => p}, socket) do
    schedule =
      if p["schedule"] == "custom",
        do: String.trim(p["schedule_custom"] || ""),
        else: p["schedule"]

    cs =
      p
      |> Map.put("schedule", schedule)
      |> cron_changeset()
      |> validate_cron_schedule(schedule)

    if cs.valid? do
      name = Changeset.get_field(cs, :name)
      editing = socket.assigns.edit_cron

      Config.put_cron(%Pepe.Config.Cron{
        id: (editing && editing.id) || new_cron_id(name),
        name: name,
        agent: blank(p["agent"]) || Config.default_agent_name(),
        prompt: Changeset.get_field(cs, :prompt),
        schedule: schedule,
        timezone: blank(p["timezone"]) || Config.default_timezone(),
        model: blank(p["model"]),
        deliver: deliver_from(p),
        # Preserve the enabled flag when editing; new tasks start enabled.
        enabled: (editing && editing.enabled) || is_nil(editing)
      })

      {:noreply,
       socket
       |> assign(crons: Config.crons(), creating: false, edit_cron: nil)
       |> put_flash(:info, (editing && gettext("Task updated.")) || gettext("Task created."))}
    else
      {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :cron))}
    end
  end

  def handle_event("ai_toggle", %{"field" => field} = p, socket),
    do: {:noreply, assign(socket, ai: AiFill.toggle(socket.assigns.ai, field, p["kind"], p["placeholder"] || ""))}

  def handle_event("ai_generate", %{"field" => field, "kind" => kind, "desc" => desc, "model" => model}, socket) do
    cond do
      desc == "" ->
        {:noreply, put_flash(socket, :error, gettext("Describe what you want first."))}

      model in [nil, ""] ->
        {:noreply, put_flash(socket, :error, gettext("Add a model first."))}

      true ->
        {:noreply,
         socket
         |> assign(ai: %{socket.assigns.ai | busy: true})
         |> start_async({:ai_fill, field}, fn -> AiFill.generate(kind, desc, model) end)}
    end
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/cron")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  defp validate_cron_schedule(cs, schedule) do
    case Pepe.Cron.parse(schedule) do
      {:error, msg} -> Changeset.add_error(cs, :schedule, gettext("Invalid: %{msg}", msg: msg))
      _ -> cs
    end
  end
end
