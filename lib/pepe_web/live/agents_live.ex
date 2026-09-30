defmodule PepeWeb.AgentsLive do
  @moduledoc "Agents section: define personas, models, tools and admin scope."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Drafts
  alias Pepe.Config
  alias Pepe.Runtime.Stats

  # The `kind` under which this screen's drafts are stored (see Pepe.Drafts).
  @draft_kind "agent"

  # Which tab each form section lives on. Every section stays in the DOM (the inactive tabs are
  # only hidden), so one form still submits every field whatever tab it is showing.
  @tabs ~w(persona model capabilities access limits)

  @impl true
  def mount(params, _session, socket) do
    # What each agent's live conversations are holding, refreshed on a tick so the page
    # shows the current cost of keeping them open, not a number from page load.
    if connected?(socket), do: :timer.send_interval(3000, self(), :footprint)

    {:ok,
     assign(socket,
       page_title: "Pepe: Agents",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       agents: Config.agents(),
       default_agent: Config.default_agent_name(),
       models: Config.models(),
       edit_agent: nil,
       form: agent_form(""),
       agent_tab: "persona",
       draft: nil,
       draft_keys: Drafts.keys(@draft_kind),
       footprint: Stats.by_agent()
     )}
  end

  @impl true
  def handle_info(:footprint, socket), do: {:noreply, assign(socket, footprint: Stats.by_agent())}

  # Which draft a form belongs to: the agent's own name, or "new" for one not created yet.
  defp draft_key(%{new?: true}), do: "new"
  defp draft_key(%{name: name}), do: name

  # Open the editor on `edit`, laying an unpublished draft over it when there is one. `base` is
  # the agent as it stands now; the draft remembers what it started from, so a change made
  # elsewhere in the meantime (the CLI, another tab) is flagged instead of silently overwritten.
  defp open_editor(socket, edit, key) do
    live = if edit.new?, do: nil, else: snapshot(edit)

    {edit, draft} =
      case Drafts.get(@draft_kind, key) do
        nil ->
          {edit, nil}

        %{data: %{"edit" => saved} = data, updated_at: at} ->
          {restore(edit, saved), %{at: at, stale?: data["base"] != live}}

        _ ->
          {edit, nil}
      end

    assign(socket,
      edit_agent: edit,
      form: agent_form(if(edit.new?, do: "", else: edit.name)),
      agent_tab: "persona",
      draft: draft
    )
  end

  # Write the form's current state to its draft. Called after every change, so leaving the page
  # or losing the browser loses nothing. The `base` is captured once, when the draft starts.
  defp remember(%{assigns: %{edit_agent: nil}} = socket), do: socket

  defp remember(socket) do
    %{edit_agent: edit, draft: draft} = socket.assigns
    key = draft_key(edit)

    base =
      case Drafts.get(@draft_kind, key) do
        %{data: %{"base" => base}} -> base
        _ -> live_snapshot(edit)
      end

    data = %{"edit" => snapshot(edit), "base" => base}
    Drafts.put(@draft_kind, key, data)

    assign(socket,
      draft: %{at: System.os_time(:second), stale?: draft != nil and draft.stale?},
      draft_keys: Drafts.keys(@draft_kind)
    )
  end

  # The agent as it is stored right now, in the same shape a draft keeps its state in.
  defp live_snapshot(%{new?: true}), do: nil

  defp live_snapshot(%{name: name}) do
    case Config.get_agent(name) do
      nil -> nil
      a -> a |> Map.from_struct() |> Map.put(:new?, false) |> Map.merge(manage_state(a.can_manage)) |> snapshot()
    end
  end

  # The form state as plain JSON-safe data. `new?` is left out: it says how the editor was
  # opened, not what was edited. A value that can't be encoded turns the snapshot into nil
  # rather than failing the keystroke that triggered it.
  defp snapshot(edit) do
    edit
    |> Map.delete(:new?)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ -> nil
  end

  # Fold a stored snapshot back over the editor's map. Only keys the form already has are
  # taken (matched by name, never turned into new atoms from stored text).
  defp restore(edit, saved) when is_map(saved) do
    Enum.reduce(edit, edit, fn {key, _current}, acc ->
      case Map.fetch(saved, to_string(key)) do
        {:ok, value} when key != :new? -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp restore(edit, _saved), do: edit

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
    remember(assign(socket, edit_agent: %{edit_agent | fallbacks: fun.(edit_agent.fallbacks || [])}))
  end

  # A chip list held in LiveView state rather than in a form field (`can_message`,
  # `manage_list`), the same way the fallback chain is.
  defp update_agent_list(socket, key, fun) do
    edit_agent = socket.assigns.edit_agent
    remember(assign(socket, edit_agent: Map.put(edit_agent, key, fun.(Map.get(edit_agent, key) || []))))
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
        <.view_header active="agents"
          icon="🧩"
          title={agents_title(@scope)}
          desc={gettext("An agent is a persona (its instructions) bound to a model, with the tools it's allowed to use. Define who they are and what they can do.")}
        >
          <button :if={!@edit_agent} phx-click="agent_new" class={btn()}>{gettext("+ New agent")}</button>
          <button :if={@edit_agent} phx-click="agent_cancel" class={btn_ghost()}>&larr; {gettext("Back to agents")}</button>
        </.view_header>

        <div class="page-body flex-1 overflow-y-auto px-4 pb-8 pt-1 sm:px-8 xl:px-14">
          <div :if={!@edit_agent} class="border-t border-zinc-800">
            <div :if={"new" in @draft_keys} class="flex flex-col gap-3 border-b border-zinc-800 py-5 sm:flex-row sm:items-center sm:justify-between">
              <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1.5">
                <span class="text-[16.5px] font-medium text-zinc-50">{gettext("New agent")}</span>
                <span class={tag(:warn)}>{gettext("Draft")}</span>
              </div>
              <button phx-click="agent_new" class={btn_ghost()}>{gettext("Continue editing")}</button>
            </div>
            <div :for={a <- scoped_agents(@agents, @scope)} class="flex flex-col gap-3 border-b border-zinc-800 py-5 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1.5">
                  <span class="text-[16.5px] font-medium text-zinc-50">{Pepe.Project.name_of(a.name)}</span>
                  <span :if={Pepe.Project.of(a.name)} class={tag(:muted)}>{Pepe.Project.of(a.name)}</span>
                  <span :if={a.name == @default_agent} class={tag(:ok)}>{gettext("default")}</span>
                  <span :if={a.name in @draft_keys} class={tag(:warn)}>{gettext("Draft")}</span>
                </div>
                <.meta_list class="mt-3">
                  <:item label={gettext("Model:")}>{a.model || gettext("(default)")} <span class="text-zinc-500">{gettext("%{count} tools", count: length(a.tools))}</span></:item>
                  <:item :if={@footprint[a.name]} label={gettext("Conversations")}>
                    {gettext("%{count} live", count: @footprint[a.name].sessions)}
                  </:item>
                  <:item :if={@footprint[a.name]} label={gettext("Memory")}>{@footprint[a.name].memory_kb} KB</:item>
                  <:item :if={a.can_message != []} label={gettext("Messages:")}>{Enum.join(a.can_message, ", ")}</:item>
                  <:item :if={a.can_manage} label={gettext("Manages:")}>{manages_text(a.can_manage)}</:item>
                </.meta_list>
              </div>
              <div class="flex shrink-0 flex-wrap gap-2">
                <button phx-click="agent_edit" phx-value-name={a.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={a.name != @default_agent} phx-click="agent_default" phx-value-name={a.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="agent_delete" phx-value-name={a.name} data-confirm={gettext("Delete agent %{name}?", name: a.name)} class={[btn_ghost(), "hover:!border-danger-ink/50 hover:!text-danger-ink"]} aria-label={gettext("Delete")}>✕</button>
              </div>
            </div>
          </div>

          <div :if={@edit_agent}>
          <.form for={@form} id="agent-form" phx-submit="agent_save" phx-change="agent_change" class="space-y-6">
            <div class="max-w-3xl space-y-6">
            <div class="text-lg font-semibold">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <%!-- Always open, never collapsible-shut: this holds the Name field the error
                  banner above points at, and a brand-new agent must land on a visible,
                  editable form rather than a stack of closed bars. --%>









            <div role="tablist" class="-mx-1 flex gap-1 overflow-x-auto border-b border-zinc-800 px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              <button
                :for={{tab, label} <- agent_tabs()}
                type="button"
                role="tab"
                phx-click="agent_tab"
                phx-value-tab={tab}
                aria-selected={to_string(@agent_tab == tab)}
                aria-controls={"agent-tab-#{tab}"}
                class={[
                  "-mb-px shrink-0 border-b-2 px-4 py-2.5 text-base font-medium transition focus-visible:outline-offset-[-3px]",
                  (@agent_tab == tab && "border-orange-400 text-orange-300") ||
                    "border-transparent text-zinc-400 hover:text-zinc-100"
                ]}
              >
                {label}
              </button>
            </div>

            <div class={tab_cls(@agent_tab, "persona")} id="agent-tab-persona" role="tabpanel">
            <.form_section id="agent-section-persona" title={gettext("Persona")}>
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

              <div>
                <label class={lbl()}>{gettext("Langfuse-managed prompt (optional)")}</label>
                <input type="text" name="langfuse_prompt" value={@edit_agent[:langfuse_prompt]} placeholder={gettext("blank = use the persona above")} class={fld()} />
                <p class={hlp()}>
                  {gettext("Uses this Langfuse prompt as the persona. Falls back to the one above.")}
                </p>
              </div>
            </.form_section>

            <.form_section id="agent-section-assembled-prompt" :if={!@edit_agent.new?} title={gettext("Assembled prompt")}>
              <details class="text-sm" open>
                <summary class="cursor-pointer text-zinc-400 hover:text-zinc-200">
                  {gettext("What the model actually sees, not just the persona above")}
                </summary>
                <p class={hlp()}>
                  {gettext("The exact system message sent on every chat. The persona is only the start.")}
                </p>
                <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap rounded-lg border border-zinc-800 bg-zinc-950 p-3 text-xs text-zinc-300">{assembled_prompt(@edit_agent)}</pre>
              </details>
            </.form_section>
            </div>

            <div class={tab_cls(@agent_tab, "model")} id="agent-tab-model" role="tabpanel">
            <.form_section id="agent-section-model" title={gettext("Model & fallbacks")}>
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
                  {gettext("Backup models, tried in order if this one fails. Usually you can skip it.")}
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

            <.form_section id="agent-section-routing" title={gettext("Complexity routing")}>
              <p class={hlp()}>
                {gettext("Optional: simple chats go to the model below, complex ones to this agent's own model.")}
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
                <p class={[hlp(), check_indent()]}>{gettext("Checks if a mid-task message is a correction and applies it. Waits if unsure.")}</p>
                <p :if={blank(@edit_agent[:triage_model]) == nil} class={[hlp(), check_indent(), "text-amber-500/80"]}>
                  {gettext("No triage model set above: the check uses this agent's own model, at its cost.")}
                </p>
              </div>

              <%!-- The complex branch isn't a choice - it's the agent's own model. Name it
                    here anyway, so the box explains the whole route without scrolling up. --%>
              <div>
                <label class={lbl()}>{gettext("Complex model")}</label>
                <div class="rounded-lg border border-zinc-800 bg-zinc-900/40 px-3 py-2 text-sm">
                  <span class="text-zinc-300">{@edit_agent[:model] || gettext("(the default model)")}</span>
                  <span class="ml-1 text-zinc-600">{gettext("(this agent's own model, chosen above)")}</span>
                </div>
              </div>
            </.form_section>

            <.form_section id="agent-section-chores" title={gettext("Chores")}>
              <p class={hlp()}>
                {gettext("Optional cheap model for small jobs, like naming chats.")}
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
                <p class={[hlp(), check_indent()]}>{gettext("Notices promises like \"remind me Friday\" and follows up on time without being asked twice.")}</p>
                <p :if={blank(@edit_agent[:utility_model]) == nil} class={[hlp(), check_indent(), "text-amber-500/80"]}>
                  {gettext("No utility model set above: this does nothing until one is.")}
                </p>
              </div>
            </.form_section>
            </div>

            <div class={tab_cls(@agent_tab, "capabilities")} id="agent-tab-capabilities" role="tabpanel">
            <.form_section id="agent-section-capabilities" title={gettext("Capabilities")}>
              <div>
                <label class={lbl()}>
                  {gettext("Tools")} <span class="text-zinc-600">{gettext("(what this agent can do)")}</span>
                  <span
                    class="ml-1 cursor-help text-zinc-600"
                    title={gettext("The text under each tool is sent to the AI model, so it stays in English.")}
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
                  {gettext("Turns off after untrusted content is read, to block hidden instructions.")}
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
                <p class={hlp()}>{gettext("Set up each hook under Privacy. Empty means no redaction.")}</p>
              </div>
            </.form_section>

            <.form_section id="agent-section-slots" title={gettext("Extension slots")}>
              <p class={hlp()}>
                {gettext("Each slot lets one plugin replace a part of the agent. Default uses the project's choice.")}
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
            </div>

            <div class={tab_cls(@agent_tab, "access")} id="agent-tab-access" role="tabpanel">
            <.form_section id="agent-section-access" title={gettext("Access")}>
              <div>
                <label class={lbl()}>{gettext("Can message (agents it may talk to)")}</label>
                <p class={hlp()}>{gettext("Pick the agents this one may message. None picked means it messages no one.")}</p>
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
            </div>

            <div class={tab_cls(@agent_tab, "limits")} id="agent-tab-limits" role="tabpanel">
            <.form_section id="agent-section-limits" title={gettext("Limits")}>
              <div>
                <label class={lbl()}>{gettext("Max steps")} <span class="text-zinc-600">{gettext("(tool rounds per task)")}</span></label>
                <input type="number" min="1" name="max_iterations" value={@edit_agent.max_iterations} placeholder={gettext("no limit")} class={fld()} />
                <p class={hlp()}>
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("No limit: the agent keeps going until the task is done.")}
                  {gettext("Set a number only to cap long tasks. A low cap can stop work halfway.")}
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
                <p class={hlp()}>{gettext("Overrides the channel default for this agent.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="exempt_message_limit" value="true" checked={@edit_agent[:exempt_message_limit]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Exempt from the project's monthly message limit")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Keeps replying after the project's monthly message cap. Spend cap still applies.")}</p>
              </div>

              <%!-- The explanation is deliberately a sibling of the label, not inside it: this
                    is a security switch, and reading (or selecting) the paragraph about it
                    must never be what flips it. --%>
              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="trust_untrusted_content" value="true" checked={@edit_agent[:trust_untrusted_content]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Trust untrusted content (act on files & pages without re-asking)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Keeps auto-approved tools running after reading files or pages. Trusted agents only.")}</p>
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
                <p class={[hlp(), check_indent()]}>{gettext("Off: search covers only this conversation. On: covers every conversation in this project.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="micro_compaction" value="true" checked={@edit_agent[:micro_compaction]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Micro-compaction (fold history gradually instead of resummarizing it all at once)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Summarizes only the oldest exchange each turn. May reduce prompt caching.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="capability_nudge" value="true" checked={@edit_agent[:capability_nudge]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Mention other capabilities after a successful task")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("The agent may add one short tip about a related feature when it fits.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="skill_learning" value="true" checked={@edit_agent[:skill_learning]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Learn from what it does (offer to save and correct its own skills)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("The agent may offer to save a multi-step task as a skill. Never without your yes.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="checkpoints" value="true" checked={@edit_agent[:checkpoints]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Keep a copy of files it changes (so /rewind can put them back)")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Keeps file copies for about two weeks so /rewind can restore them.")}</p>
              </div>

              <div>
                <label class="flex items-start gap-2.5 text-sm">
                  <input type="checkbox" name="checkpoint_shell" value="true" checked={@edit_agent[:checkpoint_shell]} class={["mt-0.5 shrink-0", checkbox_cls()]} />
                  <span>{gettext("Also cover shell commands")}</span>
                </label>
                <p class={[hlp(), check_indent()]}>{gettext("Also copies the folder around shell commands so /rewind can undo them.")}</p>
              </div>
            </.form_section>
            </div>

            </div>

            <div class="sticky -bottom-8 z-10 -mx-4 flex flex-wrap items-center justify-between gap-3 border-t border-zinc-800 bg-zinc-950/95 px-4 py-3 backdrop-blur sm:-mx-8 sm:px-8 xl:-mx-14 xl:px-14">
              <div class="min-w-0 text-sm">
                <span :if={@draft && @draft.stale?} class="text-amber-400">
                  {gettext("This agent changed since the draft was started. Saving overwrites those changes.")}
                </span>
                <span :if={@draft && !@draft.stale?} class="text-zinc-400">
                  <span class="mr-1.5 inline-block size-2 rounded-full bg-orange-400"></span>{gettext("Draft saved. It is not live until you press Save.")}
                </span>
                <span :if={!@draft} class="text-zinc-600">{gettext("No unsaved changes.")}</span>
              </div>
              <div class="flex gap-2">
                <button :if={@draft} type="button" phx-click="agent_discard_draft" data-confirm={gettext("Discard the draft and go back to the saved version?")} class={btn_ghost()}>
                  {gettext("Discard draft")}
                </button>
                <button type="button" phx-click="agent_cancel" class={btn_ghost()}>{gettext("Back")}</button>
                <button type="submit" class={btn()}>{gettext("Save")}</button>
              </div>
            </div>
          </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # The editor's tabs, in order. Their ids are the `@tabs` the event handler accepts.
  defp agent_tabs do
    [
      {"persona", gettext("Persona")},
      {"model", gettext("Model")},
      {"capabilities", gettext("Capabilities")},
      {"access", gettext("Access")},
      {"limits", gettext("Limits")}
    ]
  end

  # A tab's panel is always rendered, only hidden when it is not the active one: the form has to
  # keep submitting every field whatever tab the operator happens to be looking at.
  defp tab_cls(active, tab), do: ["space-y-6", active != tab && "hidden"]

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
    {:noreply, open_editor(socket, blank_agent(), "new")}
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

        {:noreply, open_editor(socket, edit, a.name)}
    end
  end

  # Leaving the editor keeps any draft: that is the point of it. Only Save (which publishes it)
  # and Discard throw one away.
  def handle_event("agent_cancel", _p, socket),
    do: {:noreply, assign(socket, edit_agent: nil, draft: nil, draft_keys: Drafts.keys(@draft_kind))}

  def handle_event("agent_tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, agent_tab: tab)}

  def handle_event("agent_tab", _p, socket), do: {:noreply, socket}

  def handle_event("agent_discard_draft", _p, %{assigns: %{edit_agent: nil}} = socket), do: {:noreply, socket}

  def handle_event("agent_discard_draft", _p, socket) do
    %{edit_agent: edit} = socket.assigns
    key = draft_key(edit)
    Drafts.delete(@draft_kind, key)

    fresh =
      with false <- edit.new?, %Pepe.Config.Agent{} = a <- Config.get_agent(edit.name) do
        a |> Map.from_struct() |> Map.put(:new?, false) |> Map.merge(manage_state(a.can_manage))
      else
        _ -> blank_agent()
      end

    {:noreply,
     socket
     |> assign(edit_agent: fresh, form: agent_form(if(edit.new?, do: "", else: edit.name)), draft: nil)
     |> assign(draft_keys: Drafts.keys(@draft_kind))}
  end

  # The form is live, not only read on submit: the auto-approve grid follows the tool grid
  # above it, the admin-scope picker appears the moment the mode asks for names, and the
  # "no triage/utility model set above" warnings stop contradicting the select right next
  # to them. Everything the operator has typed so far lives in `edit_agent`, so a re-render
  # never resets a field back to what was last saved.
  def handle_event("agent_change", _params, %{assigns: %{edit_agent: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("agent_change", params, socket),
    do: {:noreply, remember(assign(socket, edit_agent: merge_form(socket.assigns.edit_agent, params)))}

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
    {:noreply, remember(assign(socket, edit_agent: %{socket.assigns.edit_agent | fallbacks: []}))}
  end

  def handle_event("agent_fallback_inherit", _p, socket) do
    {:noreply, remember(assign(socket, edit_agent: %{socket.assigns.edit_agent | fallbacks: nil}))}
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
        # Published: the form's state is now the real config, so the draft has nothing left to
        # hold. The next change starts a new one.
        Drafts.delete(@draft_kind, draft_key(socket.assigns.edit_agent))
        Drafts.delete(@draft_kind, "new")

        {:noreply,
         socket
         |> assign(
           agents: Config.agents(),
           edit_agent: nil,
           draft: nil,
           draft_keys: Drafts.keys(@draft_kind),
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
        langfuse_prompt: blank(params["langfuse_prompt"]),
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
        micro_compaction: params["micro_compaction"] == "true",
        capability_nudge: params["capability_nudge"] == "true",
        skill_learning: params["skill_learning"] == "true",
        checkpoints: params["checkpoints"] == "true",
        checkpoint_shell: params["checkpoint_shell"] == "true"
    }
  end

  defp session_search_scope_param(%{"session_search_project_wide" => "true"}), do: "project"
  defp session_search_scope_param(_params), do: "self"

  # Keep what the user typed on screen and show the validation error under the field.
  defp reshow_invalid_agent(params, cs, socket) do
    edit = merge_form(socket.assigns.edit_agent, params)
    # The error points at the Name field, which lives on the Persona tab: bring that tab forward
    # whichever one the operator pressed Save from.
    {:noreply, assign(socket, edit_agent: edit, agent_tab: "persona", form: to_form(%{cs | action: :validate}, as: :agent))}
  end

  defp blank_agent do
    %{
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
      langfuse_prompt: nil,
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
      micro_compaction: false,
      capability_nudge: false,
      skill_learning: false,
      checkpoints: true,
      checkpoint_shell: false
    }
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
        langfuse_prompt: blank(params["langfuse_prompt"]),
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
        micro_compaction: params["micro_compaction"] == "true",
        capability_nudge: params["capability_nudge"] == "true",
        skill_learning: params["skill_learning"] == "true",
        checkpoints: params["checkpoints"] == "true",
        checkpoint_shell: params["checkpoint_shell"] == "true"
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
