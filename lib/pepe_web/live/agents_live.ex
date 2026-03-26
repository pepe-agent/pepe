defmodule PepeWeb.AgentsLive do
  @moduledoc "Agents section: define personas, models, tools and admin scope."
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
       page_title: "Pepe · Agents",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       agents: Config.agents(),
       default_agent: Config.default_agent_name(),
       edit_agent: nil,
       form: agent_form("")
     )}
  end

  defp agent_changeset(name) do
    {%{}, %{name: :string}}
    |> Changeset.cast(%{"name" => name}, [:name])
    |> Changeset.validate_required([:name])
  end

  defp agent_form(name), do: to_form(agent_changeset(name), as: :agent)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="agents" scope={@scope} companies={@companies} new_company={@new_company} />
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
                <span :if={Pepe.Company.of(a.name)} class="mr-1 rounded bg-indigo-800 px-1.5 text-sm text-indigo-100">{Pepe.Company.of(a.name)}</span>
                <span class="font-medium">{a.name}</span>
                <span :if={a.name == @default_agent} class="ml-2 rounded bg-green-700 px-1.5 text-sm">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <button phx-click="agent_edit" phx-value-name={a.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={a.name != @default_agent} phx-click="agent_default" phx-value-name={a.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="agent_delete" phx-value-name={a.name} data-confirm={gettext("Delete agent %{name}?", name: a.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">{gettext("Model:")} {a.model || gettext("(default)")} · {gettext("%{count} tools", count: length(a.tools))}</div>
            <div :if={a.can_message != []} class="text-sm text-zinc-500">-> {gettext("Messages:")} {Enum.join(a.can_message, ", ")}</div>
            <div :if={a.can_manage} class="text-sm text-zinc-500">⚙ {gettext("Manages:")} {manages_text(a.can_manage)}</div>
          </div>
          </div>

          <div :if={@edit_agent} class="max-w-2xl">
          <.form for={@form} phx-submit="agent_save" class="space-y-4">
            <div class="text-lg font-semibold">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("assistant")}
              readonly={!@edit_agent.new?} class={[fld(), !@edit_agent.new? && "opacity-60"]} />

            <div>
              <label class={lbl()}>{gettext("Persona (system prompt)")}</label>
              <textarea name="system_prompt" rows="3" placeholder={gettext("You are ...")} class={fld()}>{@edit_agent.system_prompt}</textarea>
            </div>

            <div>
              <label class={lbl()}>{gettext("Model")}</label>
              <select name="model" class={fld()}>
                <option value="">{gettext("(use default model)")}</option>
                <option :for={m <- model_names()} value={m} selected={m == @edit_agent.model}>{m}</option>
              </select>
            </div>

            <div>
              <label class={lbl()}>{gettext("Tools")} <span class="text-zinc-600">{gettext("(what this agent can do)")}</span></label>
              <div class="grid gap-2 sm:grid-cols-2">
                <.check_card :for={t <- Pepe.Tools.names()} name="tools[]" value={t}
                  checked={t in @edit_agent.tools} hint={tool_hint(t)} />
              </div>
            </div>

            <div>
              <label class={lbl()}>{gettext("Privacy hooks")} <span class="text-zinc-600">{gettext("(redact PII on the message flow)")}</span></label>
              <div class="grid gap-2 sm:grid-cols-2">
                <.check_card :for={h <- Pepe.Hooks.names()} name="hooks[]" value={h}
                  checked={h in (@edit_agent.hooks || [])} hint={hook_hint(h)} />
              </div>
              <p class={hlp()}>{gettext("Configure each hook (packs, model, ...) under Privacy; empty = no redaction (raw).")}</p>
            </div>

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

            <div class="flex gap-2 border-t border-zinc-800 pt-4">
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
  defp tool_hint(name) do
    case Pepe.Tools.get(name) do
      nil -> ""
      mod -> mod.spec() |> get_in(["function", "description"]) |> short_hint()
    end
  end

  defp short_hint(nil), do: ""

  defp short_hint(text) do
    text
    |> to_string()
    |> String.split(~r/(?<=[.!?])\s/, parts: 2)
    |> List.first()
    |> String.slice(0, 80)
    |> String.trim()
  end

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
      can_message: [],
      can_manage: nil,
      hooks: []
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

    if cs.valid? do
      name = raw_name |> String.trim() |> scope_name(socket.assigns.scope)
      existing = Config.get_agent(name) || %Pepe.Config.Agent{name: name}

      agent = %{
        existing
        | name: name,
          system_prompt: blank(params["system_prompt"]) || Pepe.Config.Agent.default_prompt(),
          model: blank(params["model"]),
          tools: params["tools"] || [],
          can_message: parse_list(params["can_message"]),
          can_manage: parse_manage(params["can_manage"]),
          hooks: params["hooks"] || []
      }

      Config.put_agent(agent)

      {:noreply,
       socket
       |> assign(
         agents: Config.agents(),
         edit_agent: nil,
         form: agent_form(""),
         default_agent: Config.default_agent_name()
       )
       |> put_flash(:info, gettext("Agent %{name} saved.", name: name))}
    else
      # Keep what the user typed on screen and show the error under the field.
      edit = %{
        socket.assigns.edit_agent
        | name: raw_name,
          system_prompt: params["system_prompt"] || "",
          model: blank(params["model"]),
          tools: params["tools"] || [],
          can_message: parse_list(params["can_message"]),
          can_manage: parse_manage(params["can_manage"]),
          hooks: params["hooks"] || []
      }

      {:noreply, assign(socket, edit_agent: edit, form: to_form(%{cs | action: :validate}, as: :agent))}
    end
  end

  def handle_event("agent_delete", %{"name" => name}, socket) do
    Config.delete_agent(name)

    {:noreply, assign(socket, agents: Config.agents(), default_agent: Config.default_agent_name())}
  end

  def handle_event("agent_default", %{"name" => name}, socket) do
    Config.set_default_agent(name)
    {:noreply, assign(socket, default_agent: name)}
  end

  # Shared sidebar events.
  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/agents")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}
end
