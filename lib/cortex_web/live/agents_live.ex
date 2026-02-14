defmodule CortexWeb.AgentsLive do
  @moduledoc "Agents section: define personas, models, tools and admin scope."
  use CortexWeb, :live_view
  use Gettext, backend: Cortex.Gettext

  import CortexWeb.DashUI
  import CortexWeb.DashData

  alias Cortex.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Cortex · Agents",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       agents: Config.agents(),
       default_agent: Config.default_agent_name(),
       edit_agent: nil
     )}
  end

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
          <button phx-click="agent_new" class={btn()}>{gettext("+ New agent")}</button>
        </.view_header>

        <div class="flex-1 space-y-3 overflow-y-auto p-6">
          <div :for={a <- scoped_agents(@agents, @scope)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span :if={Cortex.Company.of(a.name)} class="mr-1 rounded bg-indigo-800 px-1.5 text-xs text-indigo-100">{Cortex.Company.of(a.name)}</span>
                <span class="font-medium">{a.name}</span>
                <span :if={a.name == @default_agent} class="ml-2 rounded bg-green-700 px-1.5 text-xs">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-xs">
                <button phx-click="agent_edit" phx-value-name={a.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={a.name != @default_agent} phx-click="agent_default" phx-value-name={a.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="agent_delete" phx-value-name={a.name} data-confirm={gettext("Delete agent %{name}?", name: a.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-xs text-zinc-400">{gettext("model:")} {a.model || gettext("(default)")} · {gettext("%{count} tools", count: length(a.tools))}</div>
            <div :if={a.can_message != []} class="text-xs text-zinc-500">→ {gettext("messages:")} {Enum.join(a.can_message, ", ")}</div>
            <div :if={a.can_manage} class="text-xs text-zinc-500">⚙ {gettext("manages:")} {manages_text(a.can_manage)}</div>
          </div>

          <form :if={@edit_agent} phx-submit="agent_save" class="space-y-4 rounded-xl border border-blue-900/60 bg-blue-950/10 p-5">
            <div class="text-sm font-medium">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>

            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input name="name" value={@edit_agent.name} placeholder={gettext("assistant")} readonly={!@edit_agent.new?}
                class={[fld(), !@edit_agent.new? && "opacity-60"]} />
            </div>

            <div>
              <label class={lbl()}>{gettext("Persona (system prompt)")}</label>
              <textarea name="system_prompt" rows="3" placeholder={gettext("You are …")} class={fld()}>{@edit_agent.system_prompt}</textarea>
            </div>

            <div>
              <label class={lbl()}>{gettext("Model")}</label>
              <select name="model" class={fld()}>
                <option value="">{gettext("(use default model)")}</option>
                <option :for={m <- model_names()} value={m} selected={m == @edit_agent.model}>{m}</option>
              </select>
            </div>

            <div>
              <label class={lbl()}>{gettext("Tools")} <span class="text-zinc-600">{gettext("— what this agent can do")}</span></label>
              <div class="grid grid-cols-2 gap-1 rounded bg-zinc-900/60 p-2">
                <label :for={t <- Cortex.Tools.names()} class="flex items-center gap-1.5 text-xs text-zinc-300">
                  <input type="checkbox" name="tools[]" value={t} checked={t in @edit_agent.tools} /> {t}
                </label>
              </div>
            </div>

            <div>
              <label class={lbl()}>{gettext("Can message — agents it may talk to")}</label>
              <input name="can_message" value={Enum.join(@edit_agent.can_message, ",")} placeholder={gettext("e.g. helper, researcher")} class={fld()} />
              <p class={hlp()}>{gettext("Comma-separated agent names. Blank = talks to no one.")}</p>
            </div>

            <div>
              <label class={lbl()}>{gettext("Admin scope — which agents it can manage & train")}</label>
              <input name="can_manage" value={manage_field(@edit_agent.can_manage)} placeholder={gettext("blank")} class={fld()} />
              <p class={hlp()}>
                <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("itself only")} ·
                <code class="text-zinc-300">none</code> = {gettext("nobody")} ·
                <code class="text-zinc-300">*</code> = {gettext("all agents")} ·
                <code class="text-zinc-300">a,b</code> = {gettext("only those")}
              </p>
            </div>

            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="agent_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("agent_new", _p, socket) do
    blank = %{
      new?: true,
      name: "",
      system_prompt: "",
      model: nil,
      tools: [],
      can_message: [],
      can_manage: nil
    }

    {:noreply, assign(socket, edit_agent: blank)}
  end

  def handle_event("agent_edit", %{"name" => name}, socket) do
    case Config.get_agent(name) do
      nil -> {:noreply, socket}
      a -> {:noreply, assign(socket, edit_agent: Map.put(Map.from_struct(a), :new?, false))}
    end
  end

  def handle_event("agent_cancel", _p, socket), do: {:noreply, assign(socket, edit_agent: nil)}

  def handle_event("agent_save", params, socket) do
    name = params["name"] |> to_string() |> String.trim() |> scope_name(socket.assigns.scope)

    if name == "" do
      {:noreply, put_flash(socket, :error, gettext("Name is required."))}
    else
      existing = Config.get_agent(name) || %Cortex.Config.Agent{name: name}

      agent = %{
        existing
        | name: name,
          system_prompt: blank(params["system_prompt"]) || Cortex.Config.Agent.default_prompt(),
          model: blank(params["model"]),
          tools: params["tools"] || [],
          can_message: parse_list(params["can_message"]),
          can_manage: parse_manage(params["can_manage"])
      }

      Config.put_agent(agent)

      {:noreply,
       socket
       |> assign(
         agents: Config.agents(),
         edit_agent: nil,
         default_agent: Config.default_agent_name()
       )
       |> put_flash(:info, gettext("Agent %{name} saved.", name: name))}
    end
  end

  def handle_event("agent_delete", %{"name" => name}, socket) do
    Config.delete_agent(name)

    {:noreply,
     assign(socket, agents: Config.agents(), default_agent: Config.default_agent_name())}
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
