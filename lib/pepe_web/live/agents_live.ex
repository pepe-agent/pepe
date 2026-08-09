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

  # A chip list held in LiveView state rather than in a form field (`can_message`,
  # `manage_list`), the same way the fallback chain is.
  defp update_agent_list(socket, key, fun) do
    edit_agent = socket.assigns.edit_agent
    assign(socket, edit_agent: Map.put(edit_agent, key, fun.(Map.get(edit_agent, key) || [])))
  end

  # `can_manage`'s four modes, unpacked into the two things the form actually edits: the
  # mode itself, and (only for "list") the names. Kept apart because [] is BOTH "nobody"
  # and "specific agents, none picked yet" - one stored field can't tell those apart.
  defp manage_state(nil), do: %{manage_mode: "self", manage_list: []}
  defp manage_state([]), do: %{manage_mode: "none", manage_list: []}
  defp manage_state(["*"]), do: %{manage_mode: "all", manage_list: []}
  defp manage_state(list) when is_list(list), do: %{manage_mode: "list", manage_list: list}
  defp manage_state(_), do: %{manage_mode: "self", manage_list: []}

  defp build_manage("none", _list), do: []
  defp build_manage("all", _list), do: ["*"]
  defp build_manage("list", list), do: list
  defp build_manage(_self, _list), do: nil

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
    <div class={shell_cls()}>
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

        <div class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div :if={!@edit_agent} class="space-y-3">
          <div :for={a <- scoped_agents(@agents, @scope)} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0">
                <span :if={Pepe.Project.of(a.name)} class="mr-1 rounded bg-indigo-800 px-1.5 text-sm text-indigo-100">{Pepe.Project.of(a.name)}</span>
                <span class="font-medium">{Pepe.Project.name_of(a.name)}</span>
                <span :if={a.name == @default_agent} class="ml-2 rounded bg-green-700 px-1.5 text-sm">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
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
          <.form for={@form} id="agent-form" phx-submit="agent_save" phx-change="agent_change" class="space-y-6">
            <div class="text-lg font-semibold">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <%!-- Always open, never collapsible-shut: this holds the Name field the error
                  banner above points at, and a brand-new agent must land on a visible,
                  editable form rather than a stack of closed bars. --%>
            <.form_section collapsible open title={gettext("Persona")}>
              <div>
                <label class={lbl()} for="agent_name">{gettext("Name")}</label>
                <input
                  id="agent_name"
                  name="agent[name]"
                  value={@edit_agent.name}
                  placeholder={gettext("assistant")}
                  readonly={!@edit_agent.new?}
                  phx-debounce="blur"
                  class={[
                    fld(),
                    !@edit_agent.new? && "opacity-60",
                    @form.errors != [] && "border-red-500/70 focus:border-red-500 focus:ring-red-500/30"
                  ]}
                />
                <p :for={msg <- translate_errors(@form.errors, :name)} class="mt-1.5 text-sm text-red-400">{msg}</p>
              </div>

              <div>
                <label class={lbl()}>{gettext("Persona (system prompt)")}</label>
                <textarea name="system_prompt" rows="3" phx-debounce="blur" placeholder={gettext("You are ...")} class={fld()}>{@edit_agent.system_prompt}</textarea>
              </div>
            </.form_section>

            <.form_section collapsible open title={gettext("Model & fallbacks")}>
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
                  {gettext("If this agent's model is down or times out, Pepe retries on the backup models in order. By default it uses the backup list already set on the model connection, so you rarely need to touch this.")}
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

            <.form_section collapsible title={gettext("Complexity routing")}>
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

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="midrun_fold" value="true" checked={@edit_agent[:midrun_fold]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Fold a correction into the running turn")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("When a message arrives while this agent is still working, a check decides if it's a correction of that turn ('wait, make it 3pm instead') and steers it in, instead of always waiting for the turn to finish first. Biased toward waiting on any doubt.")}</p>
                <p :if={blank(@edit_agent[:triage_model]) == nil} class={[hlp(), check_indent(), "text-amber-500/80"]}>
                  {gettext("No triage model set above: the check runs on this agent's own model instead, at its cost and speed, on every message that arrives mid-turn.")}
                </p>
              </div>

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

            <.form_section collapsible title={gettext("Chores")}>
              <p class={hlp()}>
                {gettext("Housekeeping calls, like naming a conversation for this sidebar, don't need the agent's main model: point them at a cheap connection you already have. Left off, conversations are still named from the first few words of the request. That's free, offline, and never sends anyone's opening message anywhere to be read.")}
              </p>

              <div>
                <label class={lbl()}>{gettext("Utility model")}</label>
                <select name="utility_model" class={fld()}>
                  <option value="">{gettext("(off: name conversations without a model)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent[:utility_model]}>{m}</option>
                </select>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="commitments" value="true" checked={@edit_agent[:commitments]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Track commitments made in conversation")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Notices a stated follow-up after each turn (\"remind me Friday\", \"I'll check and tell you tomorrow\") and tracks it without being asked twice. A user's reminder comes back as a message at the right time. The agent's own promise re-runs its session first, so the work is actually done before the agent reports it done.")}</p>
                <p :if={blank(@edit_agent[:utility_model]) == nil} class={[hlp(), check_indent(), "text-amber-500/80"]}>
                  {gettext("No utility model set above: this does nothing until one is.")}
                </p>
              </div>
            </.form_section>

            <.form_section collapsible title={gettext("Capabilities")}>
              <div>
                <label class={lbl()}>
                  {gettext("Tools")} <span class="text-zinc-600">{gettext("(what this agent can do)")}</span>
                  <span
                    class="ml-1 cursor-help text-zinc-600"
                    title={gettext("The text under each tool is the instruction sent to the AI model. It stays in English on purpose: it's for the model, not a translated interface label.")}
                  >ⓘ</span>
                </label>
                <div class="grid gap-2 sm:grid-cols-2">
                  <.check_card :for={t <- Pepe.Tools.names()} name="tools[]" value={t}
                    checked={t in @edit_agent.tools} hint={tool_hint(t)} />
                </div>
              </div>

              <%!-- The same fixed set as the tool grid above, narrowed to what this agent
                    actually has: auto-approving a tool it can't call means nothing. Nothing
                    checked = ask every time, which is the safe default and needs no wording
                    about a magic blank value. --%>
              <div>
                <label class={lbl()}>{gettext("Auto-approve")} <span class="text-zinc-600">{gettext("(tools that run without asking)")}</span></label>
                <p class={hlp()}>
                  {gettext("Nothing checked = ask before every risky tool (safest).")}
                  {gettext("It's suspended automatically once the agent reads untrusted content (a fetched page, an incoming message), so prompt injection can't ride it.")}
                </p>

                <label class="mt-2 flex cursor-pointer items-start gap-2.5 rounded-lg border border-zinc-800 bg-zinc-900/40 p-2.5 text-sm transition hover:border-zinc-700">
                  <input type="checkbox" name="auto_approve_all" value="true"
                    checked={auto_approve_all?(@edit_agent.auto_approve)} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span class="text-zinc-200">{gettext("Never ask")} <code class="text-zinc-500">*</code></span>
                </label>
                <%!-- Outside the card's <label>, not inside it like check_card/1's own hint:
                      this one turns every permission prompt off, and must not flip because
                      someone clicked the sentence explaining that. --%>
                <p class={hlp()}>{gettext("Every tool this agent has runs unattended.")}</p>

                <div :if={!auto_approve_all?(@edit_agent.auto_approve)} class="mt-3 grid gap-2 sm:grid-cols-2">
                  <.check_card :for={t <- @edit_agent.tools} name="auto_approve[]" value={t}
                    checked={t in (@edit_agent.auto_approve || [])} />
                </div>
                <p :if={!auto_approve_all?(@edit_agent.auto_approve) and @edit_agent.tools == []} class={hlp()}>
                  {gettext("No tools checked above, so there is nothing to auto-approve.")}
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

            <.form_section collapsible title={gettext("Extension slots")}>
              <p class={hlp()}>
                {gettext("Each slot hands one extension point to a single installed plugin: memory search, where a shell command actually runs, how long conversations get condensed, or the whole reasoning loop. \"Default\" inherits the installation's (or project's) choice; picking a name here overrides it for this agent only.")}
              </p>
              <div class="grid gap-3 sm:grid-cols-2">
                <div :for={slot <- Pepe.Slots.names()}>
                  <label class={lbl()}>{Pepe.Slots.label_for(slot)}</label>
                  <select name={"slots[#{slot}]"} class={fld()}>
                    <option value="" selected={blank(@edit_agent.slots[slot]) == nil}>{gettext("Default")}</option>
                    <option :for={c <- Pepe.Slots.candidates(slot)} value={c.name} selected={@edit_agent.slots[slot] == c.name}>
                      {slot_option_label(c)}
                    </option>
                    <option :if={stale_slot?(@edit_agent.slots[slot], Pepe.Slots.candidates(slot))} value={@edit_agent.slots[slot]} selected>
                      {@edit_agent.slots[slot]} ({gettext("not installed")})
                    </option>
                  </select>
                  <p class={hlp()}>{Pepe.Slots.desc_for(slot)}</p>
                </div>
              </div>
            </.form_section>

            <.form_section collapsible title={gettext("Access")}>
              <div>
                <label class={lbl()}>{gettext("Can message (agents it may talk to)")}</label>
                <p class={hlp()}>{gettext("Pick the agents this one may send messages to. None picked = it talks to no one.")}</p>
                <.agent_chips
                  names={@edit_agent.can_message}
                  candidates={agent_pick_candidates(@scope, @edit_agent.name, @edit_agent.can_message)}
                  field="agent_message_candidate"
                  add="agent_message_add"
                  remove="agent_message_remove"
                />
              </div>

              <%!-- Four distinct modes used to be encoded in one free-text box, where a typo
                    ("non" for "none") silently became a one-name allow list instead of an
                    error. The mode is now a closed choice, and the names only exist when the
                    mode actually reads them. --%>
              <div>
                <label class={lbl()} for="can_manage_mode">{gettext("Admin scope (which agents it can manage & train)")}</label>
                <select id="can_manage_mode" name="can_manage_mode" class={fld()}>
                  <option value="self" selected={@edit_agent.manage_mode == "self"}>{gettext("Itself only")}</option>
                  <option value="none" selected={@edit_agent.manage_mode == "none"}>{gettext("Nobody")}</option>
                  <option value="all" selected={@edit_agent.manage_mode == "all"}>{gettext("All agents")}</option>
                  <option value="list" selected={@edit_agent.manage_mode == "list"}>{gettext("Specific agents")}</option>
                </select>
                <p class={hlp()}>{gettext("What this agent is allowed to reconfigure and train.")}</p>

                <div :if={@edit_agent.manage_mode == "list"} class="mt-2">
                  <.agent_chips
                    names={@edit_agent.manage_list}
                    candidates={agent_pick_candidates(@scope, nil, @edit_agent.manage_list)}
                    field="agent_manage_candidate"
                    add="agent_manage_add"
                    remove="agent_manage_remove"
                  />
                  <p :if={@edit_agent.manage_list == []} class={[hlp(), "text-amber-500/80"]}>
                    {gettext("No agent picked yet, so this manages nobody.")}
                  </p>
                </div>
              </div>
            </.form_section>

            <.form_section collapsible title={gettext("Limits")}>
              <div>
                <label class={lbl()}>{gettext("Max steps")} <span class="text-zinc-600">{gettext("(tool rounds per task)")}</span></label>
                <input type="number" min="1" name="max_iterations" value={@edit_agent.max_iterations} placeholder={gettext("no limit")} class={fld()} />
                <p class={hlp()}>
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("no limit: the agent runs a task until it's done (safest for real work).")}
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

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="exempt_message_limit" value="true" checked={@edit_agent[:exempt_message_limit]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Exempt from the project's monthly message limit")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("This agent keeps replying even after the project (see Projects) hits its monthly customer-message cap. Doesn't affect the separate spend cap.")}</p>
              </div>

              <%!-- The explanation is deliberately a sibling of the label, not inside it: this
                    is a security switch, and reading (or selecting) the paragraph about it
                    must never be what flips it. --%>
              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="trust_untrusted_content" value="true" checked={@edit_agent[:trust_untrusted_content]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Trust untrusted content (act on files & pages without re-asking)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Normally, once the agent takes in a file or a fetched page, its auto-approved tools go back to asking, so a hidden instruction in that content can't run unattended. Turning this on reopens that path: a hidden instruction in what the agent reads can run tools unattended. Use it only for a trusted owner's agent that must act on documents you send it.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input
                    type="checkbox"
                    name="session_search_project_wide"
                    value="true"
                    checked={@edit_agent[:session_search_scope] == "project"}
                    class={["mt-0.5 shrink-0", checkbox_cls()]}
                  />
                  <span>{gettext("Let session_search see every conversation in this project, not just the caller's own")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Off (the default), session_search only ever reaches the calling conversation's own history. On, it reaches every conversation in this project, including other agents'. Turn it on only for an agent with one operator/team on the other end, where there's no other customer's or agent's conversation to leak.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="micro_compaction" value="true" checked={@edit_agent[:micro_compaction]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Micro-compaction (fold history gradually instead of resummarizing it all at once)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Once the context window fills, each turn folds only the oldest exchange into a running summary instead of resummarizing everything from scratch: a smaller, steadier cost instead of one big stall. Trade-off: while active, the summary changes every turn, which costs some of the model provider's prompt caching.")}</p>
              </div>
            </.form_section>

            <.form_section :if={!@edit_agent.new?} collapsible title={gettext("Assembled prompt")}>
              <details class="text-sm" open>
                <summary class="cursor-pointer text-zinc-400 hover:text-zinc-200">
                  {gettext("What the model actually sees, not just the persona above")}
                </summary>
                <p class={hlp()}>
                  {gettext("This is the exact system message every real conversation with this agent sends: the persona above is only the seed, and Pepe assembles the rest around it (identity/boot files, the behavior contract, docs and skills it knows about, the current time).")}
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

  # Line up a checkbox's explanation with its label text, now that the paragraph is a
  # sibling of the <label> rather than nested inside it: the box (h-4 = 1rem) plus the
  # row's gap-2.5 (0.625rem).
  defp check_indent, do: "ml-[1.625rem]"

  defp auto_approve_all?(list), do: list == ["*"]

  # Agents this picker may still offer: everything in the current scope that isn't already
  # picked, minus `exclude` (an agent messaging itself is not a thing worth offering).
  defp agent_pick_candidates(scope, exclude, chosen) do
    taken = MapSet.new([exclude | chosen])

    scope
    |> scoped_agent_names()
    |> Enum.reject(&MapSet.member?(taken, &1))
  end

  attr :names, :list, required: true
  attr :candidates, :list, required: true
  # The <select>'s own param name, and the events its add/remove controls push. Two
  # instances of this picker live in the same form (can_message, can_manage), so neither
  # can share a name with the other.
  attr :field, :string, required: true
  attr :add, :string, required: true
  attr :remove, :string, required: true

  # The same chip list + "add one" select the fallback chain above already uses, over
  # agent names instead of model names.
  defp agent_chips(assigns) do
    ~H"""
    <div :if={@names != []} class="mt-2 flex flex-wrap gap-2">
      <span :for={name <- @names} class="inline-flex items-center gap-1.5 rounded-full bg-zinc-800 py-1 pl-2.5 pr-1.5 text-sm">
        {name}
        <button type="button" phx-click={@remove} phx-value-name={name} class="text-zinc-500 hover:text-red-400" title={gettext("Remove")}>✕</button>
      </span>
    </div>
    <select :if={@candidates != []} name={@field} phx-change={@add} class={[fld(), "mt-2"]}>
      <option value="">{gettext("+ Add an agent...")}</option>
      <option :for={n <- @candidates} value={n}>{n}</option>
    </select>
    <p :if={@candidates == [] and @names == []} class={hlp()}>{gettext("No other agent in this project to pick.")}</p>
    """
  end

  defp slot_option_label(%{name: name, default?: true}), do: name <> " " <> gettext("(builtin)")
  defp slot_option_label(%{name: name}), do: name

  # A stored override whose plugin no longer resolves as a candidate (uninstalled, or
  # transiently failed to load - Pepe.Slots.candidates/1 recomputes from disk on every
  # render) has no matching <option>, so nothing in the <select> would be `selected` and
  # the browser silently falls back to the first option ("Default") - meaning the very
  # next save of ANYTHING else on this agent would submit "" for this slot and erase the
  # override with no warning. Rendering it as its own selected option keeps it round-
  # tripping through unrelated saves instead of disappearing.
  defp stale_slot?(nil, _candidates), do: false
  defp stale_slot?(name, candidates), do: not Enum.any?(candidates, &(&1.name == name))

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
      # Every tool checked by default - same as the CLI (`mix pepe agent add` with no
      # `--tools`) and `mix pepe setup` already do. The operator unchecks what they don't
      # want instead of having to remember and pick everything they do.
      tools: Pepe.Tools.names(),
      auto_approve: [],
      can_message: [],
      can_manage: nil,
      manage_mode: "self",
      manage_list: [],
      hooks: [],
      slots: %{},
      fallbacks: nil,
      triage_model: nil,
      simple_model: nil,
      utility_model: nil,
      max_iterations: nil,
      tool_progress: nil,
      exempt_message_limit: false,
      # Missing here until the error banner made it reachable: a new agent whose save is
      # rejected (a blank name) re-renders through the same param merge every other field
      # goes through, and a key absent from this map is a KeyError, not a default.
      trust_untrusted_content: false,
      midrun_fold: false,
      commitments: false,
      session_search_scope: "self",
      micro_compaction: false
    }

    {:noreply, assign(socket, edit_agent: blank, form: agent_form(""))}
  end

  def handle_event("agent_edit", %{"name" => name}, socket) do
    case Config.get_agent(name) do
      nil ->
        {:noreply, socket}

      a ->
        edit =
          a
          |> Map.from_struct()
          |> Map.put(:new?, false)
          |> Map.merge(manage_state(a.can_manage))

        {:noreply, assign(socket, edit_agent: edit, form: agent_form(a.name))}
    end
  end

  def handle_event("agent_cancel", _p, socket),
    do: {:noreply, assign(socket, edit_agent: nil)}

  # The form is live, not only read on submit: the auto-approve grid follows the tool grid
  # above it, the admin-scope picker appears the moment the mode asks for names, and the
  # "no triage/utility model set above" warnings stop contradicting the select right next
  # to them. Everything the operator has typed so far lives in `edit_agent`, so a re-render
  # never resets a field back to what was last saved.
  def handle_event("agent_change", _params, %{assigns: %{edit_agent: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("agent_change", params, socket),
    do: {:noreply, assign(socket, edit_agent: merge_form(socket.assigns.edit_agent, params))}

  def handle_event("agent_message_add", %{"agent_message_candidate" => name}, socket) when name != "",
    do: {:noreply, update_agent_list(socket, :can_message, &(&1 ++ [name]))}

  def handle_event("agent_message_add", _p, socket), do: {:noreply, socket}

  def handle_event("agent_message_remove", %{"name" => name}, socket),
    do: {:noreply, update_agent_list(socket, :can_message, &List.delete(&1, name))}

  def handle_event("agent_manage_add", %{"agent_manage_candidate" => name}, socket) when name != "",
    do: {:noreply, update_agent_list(socket, :manage_list, &(&1 ++ [name]))}

  def handle_event("agent_manage_add", _p, socket), do: {:noreply, socket}

  def handle_event("agent_manage_remove", %{"name" => name}, socket),
    do: {:noreply, update_agent_list(socket, :manage_list, &List.delete(&1, name))}

  def handle_event("agent_save", params, socket) do
    raw_name = get_in(params, ["agent", "name"]) |> to_string()
    cs = agent_changeset(raw_name)

    if cs.valid?,
      do: save_valid_agent(params, raw_name, socket),
      else: reshow_invalid_agent(params, cs, socket)
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
    case Config.put_agent(agent_from_params(existing, params, name, socket.assigns.edit_agent)) do
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

  defp agent_from_params(existing, params, name, edit_agent) do
    %{
      existing
      | name: name,
        system_prompt: system_prompt_param(params),
        model: blank(params["model"]),
        tools: Map.get(params, "tools", []),
        auto_approve: form_auto_approve(params),
        hooks: Map.get(params, "hooks", []),
        slots: parse_slots(params["slots"]),
        max_iterations: parse_iterations(params["max_iterations"]),
        tool_progress: blank(params["tool_progress"]),
        fallbacks: edit_agent[:fallbacks],
        can_message: Map.get(edit_agent, :can_message, []),
        can_manage: build_manage(params["can_manage_mode"], Map.get(edit_agent, :manage_list, []))
    }
    |> put_agent_model_prefs(params)
    |> put_agent_switches(params)
  end

  defp system_prompt_param(params), do: blank(params["system_prompt"]) || Pepe.Config.Agent.default_prompt()

  defp put_agent_model_prefs(agent, params) do
    %{
      agent
      | triage_model: blank(params["triage_model"]),
        simple_model: blank(params["simple_model"]),
        utility_model: blank(params["utility_model"])
    }
  end

  defp put_agent_switches(agent, params) do
    %{
      agent
      | exempt_message_limit: params["exempt_message_limit"] == "true",
        trust_untrusted_content: params["trust_untrusted_content"] == "true",
        midrun_fold: params["midrun_fold"] == "true",
        commitments: params["commitments"] == "true",
        session_search_scope: session_search_scope_param(params),
        micro_compaction: params["micro_compaction"] == "true"
    }
  end

  defp session_search_scope_param(%{"session_search_project_wide" => "true"}), do: "project"
  defp session_search_scope_param(_params), do: "self"

  # Keep what the user typed on screen and show the validation error under the field.
  defp reshow_invalid_agent(params, cs, socket) do
    edit = merge_form(socket.assigns.edit_agent, params)
    {:noreply, assign(socket, edit_agent: edit, form: to_form(%{cs | action: :validate}, as: :agent))}
  end

  # Every plain form field folded back into `edit_agent`, so the screen reflects what the
  # operator has entered rather than what was last saved. Used both on every change and on
  # a rejected save. Deliberately does NOT touch the chip lists (`fallbacks`,
  # `can_message`, `manage_list`): those are LiveView state with no form field to read.
  defp merge_form(edit, params) do
    %{
      edit
      | name: get_in(params, ["agent", "name"]) || edit.name,
        system_prompt: params["system_prompt"] || edit.system_prompt,
        model: blank(params["model"]),
        tools: params["tools"] || [],
        auto_approve: form_auto_approve(params),
        hooks: params["hooks"] || [],
        slots: parse_slots(params["slots"]),
        max_iterations: parse_iterations(params["max_iterations"]),
        tool_progress: blank(params["tool_progress"]),
        manage_mode: params["can_manage_mode"] || edit.manage_mode,
        triage_model: blank(params["triage_model"]),
        simple_model: blank(params["simple_model"]),
        utility_model: blank(params["utility_model"]),
        exempt_message_limit: params["exempt_message_limit"] == "true",
        trust_untrusted_content: params["trust_untrusted_content"] == "true",
        midrun_fold: params["midrun_fold"] == "true",
        commitments: params["commitments"] == "true",
        session_search_scope: if(params["session_search_project_wide"] == "true", do: "project", else: "self"),
        micro_compaction: params["micro_compaction"] == "true"
    }
  end

  # The auto-approve grid, as the backend still wants it: the literal "*" for "never ask",
  # otherwise the checked tool names. A name that isn't among this agent's own tools can't
  # come from the rendered grid (only the checked tools get a card), and is dropped rather
  # than persisted if a forged submit sends one - auto-approving a tool the agent doesn't
  # have would sit in config.json waiting to matter the day someone grants that tool.
  defp form_auto_approve(%{"auto_approve_all" => "true"}), do: ["*"]

  defp form_auto_approve(params) do
    tools = params["tools"] || []
    (params["auto_approve"] || []) |> Enum.filter(&(&1 in tools))
  end
end
