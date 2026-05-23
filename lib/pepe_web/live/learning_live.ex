defmodule PepeWeb.LearningLive do
  @moduledoc """
  Learning (TimeLearn) section: what an agent has picked up - its skills and memory,
  newest first. Click an item to read its file and edit it in place; a skill edit is
  saved as a user override, memory to the agent's workspace.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.Reflect
  alias Pepe.Agent.Workspace
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    agent = Config.default_agent_name()

    {:ok,
     assign(socket,
       page_title: "Pepe · Learning",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       learn_agent: agent,
       learn_nodes: Pepe.Learning.timeline(agent),
       auto?: agent && Reflect.auto?(agent),
       consolidating: false,
       editing: nil,
       pending: Pepe.Approval.list()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="learn" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="✦"
          title={gettext("Learning")}
          desc={gettext("What this agent has picked up: skills it can run and memory it saved, newest first. Click any item to read and edit it.")}
        >
          <div :if={!@editing} class="flex items-center gap-2">
            <button phx-click="consolidate_now" disabled={@consolidating || is_nil(@learn_agent)} class={btn_ghost()}
              title={gettext("The agent re-reads its own memory and skills and tidies them (dedupe, prune, merge).")}>
              {if @consolidating, do: gettext("Consolidating..."), else: gettext("Consolidate now")}
            </button>
            <button phx-click="toggle_auto" disabled={is_nil(@learn_agent)} class={btn_ghost()}
              title={gettext("Run a consolidation pass automatically every night.")}>
              {if @auto?, do: gettext("Nightly: on"), else: gettext("Nightly: off")}
            </button>
            <form id="learn-agent-picker" phx-change="pick_learn_agent">
              <select name="agent" class={fld()}>
                <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @learn_agent}>{a}</option>
              </select>
            </form>
          </div>
          <button :if={@editing} phx-click="learn_close" class={btn_ghost()}>{gettext("<- Back")}</button>
        </.view_header>

        <div :if={@editing} class="flex min-h-0 flex-1 flex-col gap-3 p-6">
          <div class="text-[15px]">
            <span class="font-medium">{@editing.title}</span>
            <span class="ml-2 text-sm text-zinc-500">{@editing.path}</span>
            <span :if={@editing.note} class="ml-2 rounded bg-amber-800/40 px-1.5 text-sm text-amber-200">{@editing.note}</span>
          </div>
          <form phx-submit="learn_save" class="flex min-h-0 flex-1 flex-col gap-3">
            <textarea name="content" spellcheck="false"
              class="min-h-0 w-full flex-1 resize-none rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm leading-relaxed text-zinc-100 outline-none focus:border-orange-500 focus:ring-1 focus:ring-orange-500">{@editing.content}</textarea>
            <div class="flex gap-2">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="learn_close" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
        </div>

        <div :if={!@editing} class="flex-1 space-y-2 overflow-y-auto p-6">
          <div :if={@pending != []} class="mb-4 rounded-xl border border-amber-800/50 bg-amber-950/20 p-3">
            <div class="mb-2 text-sm font-semibold text-amber-200">
              {gettext("%{count} write(s) awaiting your review", count: length(@pending))}
              <span class="ml-1 font-normal text-amber-200/60">{gettext("(staged by consolidation, not yet applied)")}</span>
            </div>
            <div :for={p <- @pending} class="flex items-start justify-between gap-3 rounded-lg px-2 py-1.5 hover:bg-amber-900/20">
              <div class="min-w-0">
                <div class="text-[15px]"><span class="font-medium">{p["tool"]}</span> <span class="text-zinc-500">by {p["agent"]}</span></div>
                <div class="truncate font-mono text-sm text-zinc-400">{String.slice(to_string(get_in(p, ["tool_call", "function", "arguments"]) || ""), 0, 200)}</div>
              </div>
              <div class="flex shrink-0 gap-1">
                <button phx-click="approve_write" phx-value-id={p["id"]} class={btn_ghost()}>{gettext("Approve")}</button>
                <button phx-click="reject_write" phx-value-id={p["id"]} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>{gettext("Reject")}</button>
              </div>
            </div>
          </div>

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
                <span class="rounded bg-zinc-800 px-1.5 text-sm text-zinc-400">{n.source}</span>
                <span class="text-sm text-zinc-500">{learn_date(n.at)}</span>
              </div>
              <div class="truncate text-[15px] text-zinc-400">{n.summary}</div>
            </div>
          </button>
          <p :if={@learn_nodes == []} class="text-[15px] text-zinc-500">{gettext("Nothing learned yet.")}</p>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("pick_learn_agent", %{"agent" => name}, socket) do
    {:noreply, assign(socket, learn_agent: name, learn_nodes: Pepe.Learning.timeline(name), auto?: Reflect.auto?(name))}
  end

  def handle_event("consolidate_now", _p, %{assigns: %{learn_agent: name}} = socket) when is_binary(name) do
    parent = self()
    Task.start(fn -> send(parent, {:consolidated, name, Pepe.Agent.consolidate(name)}) end)
    {:noreply, assign(socket, consolidating: true)}
  end

  def handle_event("consolidate_now", _p, socket), do: {:noreply, socket}

  def handle_event("toggle_auto", _p, %{assigns: %{learn_agent: name}} = socket) when is_binary(name) do
    if Reflect.auto?(name) do
      Reflect.unschedule_auto(name)
      {:noreply, socket |> assign(auto?: false) |> put_flash(:info, gettext("Nightly consolidation off for %{agent}.", agent: name))}
    else
      {:ok, cron} = Reflect.schedule_auto(name)

      {:noreply,
       socket
       |> assign(auto?: true)
       |> put_flash(:info, gettext("Nightly consolidation on for %{agent} at %{at}.", agent: name, at: cron.schedule))}
    end
  end

  def handle_event("toggle_auto", _p, socket), do: {:noreply, socket}

  def handle_event("learn_open", %{"kind" => kind, "title" => title}, socket) do
    {:noreply, assign(socket, editing: load_node(kind, title, socket.assigns.learn_agent))}
  end

  def handle_event("learn_close", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("learn_save", %{"content" => content}, socket) do
    case socket.assigns.editing do
      %{path: path} when is_binary(path) ->
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

  def handle_event("approve_write", %{"id" => id}, socket) do
    flash =
      case Pepe.Approval.approve(id) do
        {:ok, _} -> {:info, gettext("Approved and applied.")}
        {:error, _} -> {:error, gettext("That write is no longer pending.")}
      end

    {:noreply,
     socket
     |> assign(pending: Pepe.Approval.list(), learn_nodes: Pepe.Learning.timeline(socket.assigns.learn_agent))
     |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  def handle_event("reject_write", %{"id" => id}, socket) do
    Pepe.Approval.reject(id)
    {:noreply, socket |> assign(pending: Pepe.Approval.list()) |> put_flash(:info, gettext("Rejected, nothing was written."))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/learn")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  @impl true
  def handle_info({:consolidated, name, result}, socket) do
    flash =
      case result do
        {:ok, summary, _} -> {:info, gettext("Consolidated: %{summary}", summary: String.slice(to_string(summary), 0, 160))}
        {:error, _} -> {:error, gettext("Consolidation could not run.")}
      end

    socket =
      socket
      |> assign(consolidating: false, learn_nodes: Pepe.Learning.timeline(name))
      |> put_flash(elem(flash, 0), elem(flash, 1))

    {:noreply, socket}
  end

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
      note: override? && gettext("Editing the built-in: saving creates your own copy")
    }
  end

  defp load_node("memory", title, agent) do
    base = Workspace.dir(agent)
    path = Path.join(base, title)

    # `title` arrives from a client event param; a value like `../../etc/cron.d/x` would escape the
    # workspace and turn the editor's File.write! into an arbitrary write. Only open a path that
    # stays inside the agent's workspace; otherwise hand back a non-writable node.
    if contained?(base, path) do
      %{title: title, path: path, content: read(path), note: nil}
    else
      %{title: title, path: nil, content: "", note: gettext("Invalid path.")}
    end
  end

  defp contained?(base, path) do
    base = Path.expand(base)
    full = Path.expand(path)
    full == base or String.starts_with?(full, base <> "/")
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> body
      _ -> ""
    end
  end
end
