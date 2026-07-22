defmodule PepeWeb.AgentsLive do
  @moduledoc "Agents section: define personas, models, tools and admin scope."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Config
  alias Pepe.Runtime.Stats

  @impl true
  def mount(params, _session, socket) do
    # What each agent's live conversations are holding, refreshed on a tick so the page
    # shows the current cost of keeping them open, not a number from page load.
    if connected?(socket), do: :timer.send_interval(3000, self(), :footprint)

    {:ok,
     assign(socket,
       page_title: "Pepe · Agents",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       agents: Config.agents(),
       default_agent: Config.default_agent_name(),
       models: Config.models(),
       edit_agent: nil,
       form: agent_form(""),
       footprint: Stats.by_agent()
     )}
  end

  @impl true
  def handle_info(:footprint, socket), do: {:noreply, assign(socket, footprint: Stats.by_agent())}

  defp agent_changeset(name) do
    {%{}, %{name: :string}}
    |> Changeset.cast(%{"name" => name}, [:name])
    |> Changeset.validate_required([:name])
  end

  defp agent_form(name), do: to_form(agent_changeset(name), as: :agent)

  # Other connections this agent's own override chain may use: not its primary
  # model, not already chosen. Only meaningful once `fallbacks` is a list (the
  # agent has opted out of inheriting the connection's own chain).
  defp agent_fallback_candidates(models, scope, edit_agent) do
    taken = MapSet.new([edit_agent.model | edit_agent.fallbacks || []])

    models
    |> scoped_models(scope)
    |> Enum.reject(&MapSet.member?(taken, &1.name))
  end

  defp update_agent_fallbacks(socket, fun) do
    edit_agent = socket.assigns.edit_agent
    assign(socket, edit_agent: %{edit_agent | fallbacks: fun.(edit_agent.fallbacks || [])})
  end

  defp move_fallback(list, name, dir) do
    case Enum.find_index(list, &(&1 == name)) do
      nil ->
        list

      i ->
        j = if dir == "up", do: i - 1, else: i + 1

        if j >= 0 and j < length(list) do
          list |> List.delete_at(i) |> List.insert_at(j, name)
        else
          list
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="agents" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🧩"
          title={agents_title(@scope)}
          desc={gettext("An agent is a persona (its instructions) bound to a model, with the tools it's allowed to use. Define who they are and what they can do.")}
        >
          <button :if={!@edit_agent} phx-click="agent_new" class={btn()}>{gettext("+ New agent")}</button>
          <button :if={@edit_agent} phx-click="agent_cancel" class={btn_ghost()}>&larr; {gettext("Back to agents")}</button>
        </.view_header>

        <div class="flex-1 overflow-y-auto p-6">
          <div :if={!@edit_agent} class="space-y-3">
          <div :for={a <- scoped_agents(@agents, @scope)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span :if={Pepe.Project.of(a.name)} class="mr-1 rounded bg-indigo-800 px-1.5 text-sm text-indigo-100">{Pepe.Project.of(a.name)}</span>
                <span class="font-medium">{Pepe.Project.name_of(a.name)}</span>
                <span :if={a.name == @default_agent} class="ml-2 rounded bg-green-700 px-1.5 text-sm">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <button phx-click="agent_edit" phx-value-name={a.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={a.name != @default_agent} phx-click="agent_default" phx-value-name={a.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="agent_delete" phx-value-name={a.name} data-confirm={gettext("Delete agent %{name}?", name: a.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">{gettext("Model:")} {a.model || gettext("(default)")} · {gettext("%{count} tools", count: length(a.tools))}</div>
            <div :if={@footprint[a.name]} class="text-sm text-zinc-500">
              {gettext("%{count} live conversations", count: @footprint[a.name].sessions)} · {@footprint[a.name].memory_kb} KB
            </div>
            <div :if={a.can_message != []} class="text-sm text-zinc-500">-> {gettext("Messages:")} {Enum.join(a.can_message, ", ")}</div>
            <div :if={a.can_manage} class="text-sm text-zinc-500">⚙ {gettext("Manages:")} {manages_text(a.can_manage)}</div>
          </div>
          </div>

          <div :if={@edit_agent} class="max-w-2xl">
          <.form for={@form} phx-submit="agent_save" class="space-y-6">
            <div class="text-lg font-semibold">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <.form_section title={gettext("Persona")}>
              <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("assistant")}
                readonly={!@edit_agent.new?} class={[fld(), !@edit_agent.new? && "opacity-60"]} />

              <div>
                <label class={lbl()}>{gettext("Persona (system prompt)")}</label>
                <textarea name="system_prompt" rows="3" placeholder={gettext("You are ...")} class={fld()}>{@edit_agent.system_prompt}</textarea>
              </div>
            </.form_section>

            <.form_section title={gettext("Model & fallbacks")}>
              <div>
                <label class={lbl()}>{gettext("Model")}</label>
                <select name="model" class={fld()}>
                  <option value="">{gettext("(use default model)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent.model}>{m}</option>
                </select>
              </div>

              <div>
                <label class={lbl()}>{gettext("Backup models")}</label>
                <p class={hlp()}>
                  {gettext("If this agent's model is down or times out, Pepe automatically retries the request on a backup model, in order. By default it uses the backup list already set on the model connection — you rarely need to touch this.")}
                </p>

                <div :if={@edit_agent.fallbacks == nil} class="mt-2 flex items-center justify-between gap-3 text-sm">
                  <span class="text-zinc-400">{gettext("Using the model connection's backup list.")}</span>
                  <button type="button" phx-click="agent_fallback_override" class="shrink-0 font-medium text-orange-400 hover:text-orange-300">{gettext("Set a custom list for this agent")}</button>
                </div>

                <div :if={@edit_agent.fallbacks != nil}>
                  <div :if={@edit_agent.fallbacks != []} class="mt-2 flex flex-wrap gap-2">
                    <span :for={{name, i} <- Enum.with_index(@edit_agent.fallbacks)} class="inline-flex items-center gap-1.5 rounded-full bg-zinc-800 py-1 pl-2.5 pr-1.5 text-sm">
                      <span class="text-zinc-600">{i + 1}.</span>
                      {name}
                      <button type="button" phx-click="agent_fallback_move" phx-value-name={name} phx-value-dir="up" disabled={i == 0} class="text-zinc-500 hover:text-zinc-200 disabled:opacity-20" title={gettext("Move earlier")}>↑</button>
                      <button type="button" phx-click="agent_fallback_move" phx-value-name={name} phx-value-dir="down" disabled={i == length(@edit_agent.fallbacks) - 1} class="text-zinc-500 hover:text-zinc-200 disabled:opacity-20" title={gettext("Move later")}>↓</button>
                      <button type="button" phx-click="agent_fallback_remove" phx-value-name={name} class="text-zinc-500 hover:text-red-400" title={gettext("Remove")}>✕</button>
                    </span>
                  </div>
                  <select :if={agent_fallback_candidates(@models, @scope, @edit_agent) != []} name="agent_fallback_candidate" phx-change="agent_fallback_add" class={[fld(), "mt-2"]}>
                    <option value="">{gettext("+ Add a fallback...")}</option>
                    <option :for={m <- agent_fallback_candidates(@models, @scope, @edit_agent)} value={m.name}>{m.name}</option>
                  </select>
                  <button type="button" phx-click="agent_fallback_inherit" class="mt-2 text-sm font-medium text-zinc-400 hover:text-zinc-200">{gettext("Use the connection's default instead")}</button>
                </div>
              </div>
            </.form_section>

            <.form_section title={gettext("Complexity routing")}>
              <p class={hlp()}>
                {gettext("Optional: checks if the chat is simple or complex before the first reply. Simple -> the model below handles it. Complex -> this agent's own model (above) handles it. Best-effort: if the check fails, this agent's own model answers directly.")}
              </p>

              <div>
                <label class={lbl()}>{gettext("Triage model")}</label>
                <select name="triage_model" class={fld()}>
                  <option value="">{gettext("(off)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent[:triage_model]}>{m}</option>
                </select>
              </div>

              <div>
                <label class={lbl()}>{gettext("Simple model")}</label>
                <select name="simple_model" class={fld()}>
                  <option value="">{gettext("(none)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent[:simple_model]}>{m}</option>
                </select>
              </div>

              <label class="flex items-start gap-2.5 text-sm">
                <input type="checkbox" name="midrun_fold" value="true" checked={@edit_agent[:midrun_fold]} class="mt-0.5" />
                <span>
                  {gettext("Fold a correction into the running turn")}
                  <p class={hlp()}>{gettext("When a message arrives while this agent is still working, a check decides if it's a correction of that turn ('wait, make it 3pm instead') and steers it in, instead of always waiting for the turn to finish first. Biased toward waiting on any doubt.")}</p>
                  <p :if={blank(@edit_agent[:triage_model]) == nil} class={[hlp(), "text-amber-500/80"]}>
                    {gettext("No triage model set above: the check runs on this agent's own model instead, at its cost and speed, on every message that arrives mid-turn.")}
                  </p>
                </span>
              </label>

              <%!-- The complex branch isn't a choice - it's the agent's own model. Name it
                    here anyway, so the box explains the whole route without scrolling up. --%>
              <div>
                <label class={lbl()}>{gettext("Complex model")}</label>
                <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 px-3 py-2 text-sm">
                  <span class="text-zinc-300">{@edit_agent[:model] || gettext("(the default model)")}</span>
                  <span class="ml-1 text-zinc-600">{gettext("· this agent's own model, chosen above")}</span>
                </div>
              </div>
            </.form_section>

            <.form_section title={gettext("Chores")}>
              <p class={hlp()}>
                {gettext("Some calls are not the agent thinking, they are the agent tidying up: naming a conversation so this sidebar reads like something. Point them at a cheap connection you already have. Left off, a conversation is still named, from the first few words of what was asked - free, offline, and nobody's opening message is sent anywhere to be read.")}
              </p>

              <div>
                <label class={lbl()}>{gettext("Utility model")}</label>
                <select name="utility_model" class={fld()}>
                  <option value="">{gettext("(off: name conversations without a model)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent[:utility_model]}>{m}</option>
                </select>
              </div>

              <label class="flex items-start gap-2.5 text-sm">
                <input type="checkbox" name="commitments" value="true" checked={@edit_agent[:commitments]} class="mt-0.5" />
                <span>
                  {gettext("Track commitments made in conversation")}
                  <p class={hlp()}>{gettext("Notices a stated follow-up after each turn (\"remind me Friday\", \"I'll check and tell you tomorrow\") and tracks it without being asked twice. A user's own reminder gets a message back at the right time; this agent's own promise re-runs its session so the work actually happens before anything is said to have been done.")}</p>
                  <p :if={blank(@edit_agent[:utility_model]) == nil} class={[hlp(), "text-amber-500/80"]}>
                    {gettext("No utility model set above: this does nothing until one is.")}
                  </p>
                </span>
              </label>
            </.form_section>

            <.form_section title={gettext("Capabilities")}>
              <div>
                <label class={lbl()}>
                  {gettext("Tools")} <span class="text-zinc-600">{gettext("(what this agent can do)")}</span>
                  <span
                    class="ml-1 cursor-help text-zinc-600"
                    title={gettext("The text under each tool is what it tells the AI model, always in English on purpose - it's an instruction for the model, not a translated interface label.")}
                  >ⓘ</span>
                </label>
                <div class="grid gap-2 sm:grid-cols-2">
                  <.check_card :for={t <- Pepe.Tools.names()} name="tools[]" value={t}
                    checked={t in @edit_agent.tools} hint={tool_hint(t)} />
                </div>
              </div>

              <div>
                <label class={lbl()}>{gettext("Auto-approve")} <span class="text-zinc-600">{gettext("(tools that run without asking)")}</span></label>
                <input name="auto_approve" value={Enum.join(@edit_agent.auto_approve || [], ",")} placeholder={gettext("blank")} class={fld()} />
                <p class={hlp()}>
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("ask before every risky tool (safest)")} ·
                  <code class="text-zinc-300">*</code> = {gettext("never ask")} · {gettext("or a comma-separated list of tool names.")}
                  {gettext("It's suspended automatically once the agent reads untrusted content (a fetched page, an incoming message), so prompt injection can't ride it.")}
                </p>
              </div>

              <div>
                <label class={lbl()}>{gettext("Privacy hooks")} <span class="text-zinc-600">{gettext("(redact PII on the message flow)")}</span></label>
                <div class="grid gap-2 sm:grid-cols-2">
                  <.check_card :for={h <- Pepe.Hooks.names()} name="hooks[]" value={h}
                    checked={h in (@edit_agent.hooks || [])} hint={hook_hint(h)} />
                </div>
                <p class={hlp()}>{gettext("Configure each hook (packs, model, ...) under Privacy; empty = no redaction (raw).")}</p>
              </div>
            </.form_section>

            <.form_section title={gettext("Access")}>
              <div>
                <label class={lbl()}>{gettext("Can message (agents it may talk to)")}</label>
                <input name="can_message" value={Enum.join(@edit_agent.can_message, ",")} placeholder={gettext("e.g. helper, researcher")} class={fld()} />
                <p class={hlp()}>{gettext("Comma-separated agent names. Blank = talks to no one.")}</p>
              </div>

              <div>
                <label class={lbl()}>{gettext("Admin scope (which agents it can manage & train)")}</label>
                <input name="can_manage" value={manage_field(@edit_agent.can_manage)} placeholder={gettext("blank")} class={fld()} />
                <p class={hlp()}>
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("itself only")} ·
                  <code class="text-zinc-300">none</code> = {gettext("nobody")} ·
                  <code class="text-zinc-300">*</code> = {gettext("all agents")} ·
                  <code class="text-zinc-300">a,b</code> = {gettext("only those")}
                </p>
              </div>
            </.form_section>

            <.form_section title={gettext("Limits")}>
              <div>
                <label class={lbl()}>{gettext("Max steps")} <span class="text-zinc-600">{gettext("(tool rounds per task)")}</span></label>
                <input type="number" min="1" name="max_iterations" value={@edit_agent.max_iterations} placeholder={gettext("no limit")} class={fld()} />
                <p class={hlp()}>
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("no limit — the agent runs a task until it's done (safest for real work).")}
                  {gettext("Set a number only to deliberately cap long tasks. A low cap makes the agent quit multi-step work halfway and reply with what's left unfinished.")}
                </p>
              </div>

              <div>
                <label class={lbl()}>{gettext("Progress display")} <span class="text-zinc-600">{gettext("(while this agent works)")}</span></label>
                <select name="tool_progress" class={fld()}>
                  <option value="" selected={@edit_agent.tool_progress in [nil, ""]}>{gettext("Use the channel's setting")}</option>
                  <option value="reaction" selected={@edit_agent.tool_progress == "reaction"}>{gettext("React")}</option>
                  <option value="verbose" selected={@edit_agent.tool_progress == "verbose"}>{gettext("Detailed")}</option>
                  <option value="ambient" selected={@edit_agent.tool_progress == "ambient"}>{gettext("Ambient")}</option>
                  <option value="off" selected={@edit_agent.tool_progress == "off"}>{gettext("Nothing")}</option>
                </select>
                <p class={hlp()}>{gettext("Overrides the channel default for this agent, so one agent can be detailed and another quiet on the same bot.")}</p>
              </div>

              <label class="flex items-start gap-2.5 text-sm">
                <input type="checkbox" name="exempt_message_limit" value="true" checked={@edit_agent[:exempt_message_limit]} class="mt-0.5" />
                <span>
                  {gettext("Exempt from the project's monthly message limit")}
                  <p class={hlp()}>{gettext("This agent keeps replying even after the project (see Projects) hits its monthly customer-message cap. Doesn't affect the separate spend cap.")}</p>
                </span>
              </label>

              <label class="flex items-start gap-2.5 text-sm">
                <input type="checkbox" name="trust_untrusted_content" value="true" checked={@edit_agent[:trust_untrusted_content]} class="mt-0.5" />
                <span>
                  {gettext("Trust untrusted content (act on files & pages without re-asking)")}
                  <p class={hlp()}>{gettext("Normally, once the agent takes in a file or a fetched page, its auto-approved tools go back to asking, so a hidden instruction in that content can't run unattended. Turn this on for a trusted owner's agent that must act on documents you send it — it reopens that path, so only for an agent you trust for exactly that.")}</p>
                </span>
              </label>
            </.form_section>

            <.form_section :if={!@edit_agent.new?} title={gettext("Assembled prompt")}>
              <details class="text-sm">
                <summary class="cursor-pointer text-zinc-400 hover:text-zinc-200">
                  {gettext("What the model actually sees, not just the persona above")}
                </summary>
                <p class={hlp()}>
                  {gettext("The persona field above is only the seed - this is it plus everything Pepe assembles around it (identity/boot files, the behavior contract, docs and skills it knows about, the current time). Exactly what every real conversation with this agent sends as the system message.")}
                </p>
                <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded-lg border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-300">{assembled_prompt(@edit_agent)}</pre>
              </details>
            </.form_section>

            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="agent_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # A short, one-line description for a tool, taken from its spec.
  defp tool_hint(name), do: Pepe.Tools.summary(name)

  # The exact system message a real conversation with this agent would get - the same
  # Pepe.Agent.Workspace.system_prompt/1 every surface (Session, Runtime, the /v1 API) already
  # goes through, not the bare persona field the form above edits.
  defp assembled_prompt(agent), do: Pepe.Agent.Workspace.system_prompt(agent)

  defp hook_hint("pii_redact"), do: gettext("Regex: CPF, email, cards, phones")
  defp hook_hint("llm_redact"), do: gettext("A local model masks names/free text (reversible)")
  defp hook_hint("http_redact"), do: gettext("Your own redaction endpoint")
  defp hook_hint("presidio"), do: gettext("Microsoft Presidio over HTTP")
  defp hook_hint(_), do: ""

  @impl true
  def handle_event("agent_new", _p, socket) do
    blank = %{
      new?: true,
      name: "",
      system_prompt: "",
      model: nil,
      tools: [],
      auto_approve: [],
      can_message: [],
      can_manage: nil,
      hooks: [],
      fallbacks: nil,
      triage_model: nil,
      simple_model: nil,
      utility_model: nil,
      max_iterations: nil,
      tool_progress: nil,
      exempt_message_limit: false,
      midrun_fold: false,
      commitments: false
    }

    {:noreply, assign(socket, edit_agent: blank, form: agent_form(""))}
  end

  def handle_event("agent_edit", %{"name" => name}, socket) do
    case Config.get_agent(name) do
      nil ->
        {:noreply, socket}

      a ->
        {:noreply,
         assign(socket,
           edit_agent: Map.put(Map.from_struct(a), :new?, false),
           form: agent_form(a.name)
         )}
    end
  end

  def handle_event("agent_cancel", _p, socket),
    do: {:noreply, assign(socket, edit_agent: nil)}

  def handle_event("agent_save", params, socket) do
    raw_name = get_in(params, ["agent", "name"]) |> to_string()
    cs = agent_changeset(raw_name)

    if cs.valid?,
      do: save_valid_agent(params, raw_name, socket),
      else: reshow_invalid_agent(params, raw_name, cs, socket)
  end

  def handle_event("agent_delete", %{"name" => name}, socket) do
    Config.delete_agent(name)

    {:noreply, assign(socket, agents: Config.agents(), default_agent: Config.default_agent_name())}
  end

  def handle_event("agent_default", %{"name" => name}, socket) do
    Config.set_default_agent(name)
    {:noreply, assign(socket, default_agent: name)}
  end

  def handle_event("agent_fallback_override", _p, socket) do
    {:noreply, assign(socket, edit_agent: %{socket.assigns.edit_agent | fallbacks: []})}
  end

  def handle_event("agent_fallback_inherit", _p, socket) do
    {:noreply, assign(socket, edit_agent: %{socket.assigns.edit_agent | fallbacks: nil})}
  end

  def handle_event("agent_fallback_add", %{"agent_fallback_candidate" => name}, socket) when name != "" do
    {:noreply, update_agent_fallbacks(socket, &(&1 ++ [name]))}
  end

  def handle_event("agent_fallback_add", _params, socket), do: {:noreply, socket}

  def handle_event("agent_fallback_remove", %{"name" => name}, socket) do
    {:noreply, update_agent_fallbacks(socket, &List.delete(&1, name))}
  end

  def handle_event("agent_fallback_move", %{"name" => name, "dir" => dir}, socket) do
    {:noreply, update_agent_fallbacks(socket, &move_fallback(&1, name, dir))}
  end

  # Shared sidebar events.
  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/agents")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp save_valid_agent(params, raw_name, socket) do
    name = raw_name |> String.trim() |> scope_name(socket.assigns.scope)
    existing = Config.get_agent(name)
    # `existing` is found case-insensitively, which is right for an edit (the name field is
    # readonly then, so a match here is always the same agent) but wrong for a genuinely new
    # agent: reusing a different-case match's id would silently overwrite it with this form's
    # values. Refuse instead, the same class of bug `Config.put_agent/1` itself now guards
    # against, but this call always passes an explicit `id` so that guard can't see it coming.
    creating? = socket.assigns.edit_agent[:new?]

    if creating? and existing do
      save_agent_name_collision(socket, name)
    else
      save_agent(socket, params, name, existing || %Pepe.Config.Agent{name: name})
    end
  end

  defp save_agent_name_collision(socket, name) do
    {:noreply,
     put_flash(socket, :error, gettext("An agent named %{name} already exists (maybe with different capitalization).", name: name))}
  end

  defp save_agent(socket, params, name, existing) do
    agent = %{
      existing
      | name: name,
        system_prompt: blank(params["system_prompt"]) || Pepe.Config.Agent.default_prompt(),
        model: blank(params["model"]),
        tools: params["tools"] || [],
        auto_approve: parse_list(params["auto_approve"]),
        can_message: parse_list(params["can_message"]),
        can_manage: parse_manage(params["can_manage"]),
        hooks: params["hooks"] || [],
        max_iterations: parse_iterations(params["max_iterations"]),
        tool_progress: blank(params["tool_progress"]),
        # Chip-list state lives in `edit_agent` (LiveView state), not `params` -
        # read from there so nil (inherit) vs [] (explicit none) survives.
        fallbacks: socket.assigns.edit_agent[:fallbacks],
        triage_model: blank(params["triage_model"]),
        simple_model: blank(params["simple_model"]),
        utility_model: blank(params["utility_model"]),
        exempt_message_limit: params["exempt_message_limit"] == "true",
        trust_untrusted_content: params["trust_untrusted_content"] == "true",
        midrun_fold: params["midrun_fold"] == "true",
        commitments: params["commitments"] == "true"
    }

    case Config.put_agent(agent) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           agents: Config.agents(),
           edit_agent: nil,
           form: agent_form(""),
           default_agent: Config.default_agent_name()
         )
         |> put_flash(:info, gettext("Agent %{name} saved.", name: name))}

      {:error, :name_collision} ->
        save_agent_name_collision(socket, name)

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't save %{name}: the name must be letters, digits, - or _.", name: name)
         )}
    end
  end

  # Keep what the user typed on screen and show the validation error under the field.
  defp reshow_invalid_agent(params, raw_name, cs, socket) do
    edit = %{
      socket.assigns.edit_agent
      | name: raw_name,
        system_prompt: params["system_prompt"] || "",
        model: blank(params["model"]),
        tools: params["tools"] || [],
        auto_approve: parse_list(params["auto_approve"]),
        can_message: parse_list(params["can_message"]),
        can_manage: parse_manage(params["can_manage"]),
        hooks: params["hooks"] || [],
        max_iterations: parse_iterations(params["max_iterations"]),
        tool_progress: blank(params["tool_progress"]),
        triage_model: blank(params["triage_model"]),
        simple_model: blank(params["simple_model"]),
        utility_model: blank(params["utility_model"]),
        exempt_message_limit: params["exempt_message_limit"] == "true",
        trust_untrusted_content: params["trust_untrusted_content"] == "true",
        midrun_fold: params["midrun_fold"] == "true",
        commitments: params["commitments"] == "true"
    }

    {:noreply, assign(socket, edit_agent: edit, form: to_form(%{cs | action: :validate}, as: :agent))}
  end
end
