defmodule PepeWeb.LearningLive do
  @moduledoc """
  Learning (TimeLearn) section: what an agent has picked up — its skills and memory,
  newest first. Click an item to read its file and edit it in place; a skill edit is
  saved as a user override, memory to the agent's workspace.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.Workspace
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    agent = Config.default_agent_name()

    {:ok,
     assign(socket,
       page_title: "Pepe · Learning",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       learn_agent: agent,
       learn_nodes: Pepe.Learning.timeline(agent),
       editing: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="learn" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="✦"
          title={gettext("Learning")}
          desc={gettext("What this agent has picked up — skills it can run and memory it saved, newest first. Click any item to read and edit it.")}
        >
          <form :if={!@editing} phx-change="pick_learn_agent">
            <select name="agent" class={fld()}>
              <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @learn_agent}>{a}</option>
            </select>
          </form>
          <button :if={@editing} phx-click="learn_close" class={btn_ghost()}>{gettext("← Back")}</button>
        </.view_header>

        <div :if={@editing} class="flex min-h-0 flex-1 flex-col gap-3 p-6">
          <div class="text-sm">
            <span class="font-medium">{@editing.title}</span>
            <span class="ml-2 text-xs text-zinc-500">{@editing.path}</span>
            <span :if={@editing.note} class="ml-2 rounded bg-amber-800/40 px-1.5 text-xs text-amber-200">{@editing.note}</span>
          </div>
          <form phx-submit="learn_save" class="flex min-h-0 flex-1 flex-col gap-3">
            <textarea name="content" spellcheck="false"
              class="min-h-0 w-full flex-1 resize-none rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-xs leading-relaxed text-zinc-100 outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500">{@editing.content}</textarea>
            <div class="flex gap-2">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="learn_close" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
        </div>

        <div :if={!@editing} class="flex-1 space-y-2 overflow-y-auto p-6">
          <button
            :for={n <- @learn_nodes}
            phx-click="learn_open"
            phx-value-kind={n.kind}
            phx-value-title={n.title}
            class="flex w-full gap-3 rounded-lg p-2 text-left transition hover:bg-zinc-800/60"
          >
            <span class="text-lg">{learn_icon(n.kind)}</span>
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium">{n.title}</span>
                <span class="rounded bg-zinc-800 px-1.5 text-xs text-zinc-400">{n.source}</span>
                <span class="text-xs text-zinc-500">{learn_date(n.at)}</span>
              </div>
              <div class="truncate text-sm text-zinc-400">{n.summary}</div>
            </div>
          </button>
          <p :if={@learn_nodes == []} class="text-sm text-zinc-500">{gettext("Nothing learned yet.")}</p>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("pick_learn_agent", %{"agent" => name}, socket) do
    {:noreply, assign(socket, learn_agent: name, learn_nodes: Pepe.Learning.timeline(name))}
  end

  def handle_event("learn_open", %{"kind" => kind, "title" => title}, socket) do
    {:noreply, assign(socket, editing: load_node(kind, title, socket.assigns.learn_agent))}
  end

  def handle_event("learn_close", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("learn_save", %{"content" => content}, socket) do
    case socket.assigns.editing do
      %{path: path} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)

        {:noreply,
         socket
         |> assign(
           editing: nil,
           learn_nodes: Pepe.Learning.timeline(socket.assigns.learn_agent)
         )
         |> put_flash(:info, gettext("Saved %{title}.", title: Path.basename(path)))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/learn")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  # Resolve a learning node to the file to show and where an edit is written. A skill
  # edit is saved as a user override (never the read-only built-in copy); memory edits
  # write back to the agent's workspace file.
  defp load_node("skill", title, _agent) do
    user = Path.join(Workspace.skills_dir(), "#{title}.md")
    builtin = Path.join(Application.app_dir(:pepe, "priv/skills"), "#{title}.md")
    override? = not File.exists?(user)

    %{
      title: title,
      path: user,
      content: read(if(File.exists?(user), do: user, else: builtin)),
      note: override? && gettext("editing the built-in — saving creates your own copy")
    }
  end

  defp load_node("memory", title, agent) do
    path = Path.join(Workspace.dir(agent), title)
    %{title: title, path: path, content: read(path), note: nil}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> body
      _ -> ""
    end
  end
end
