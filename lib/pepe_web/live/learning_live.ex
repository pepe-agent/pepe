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
    scope = params["scope"] || "all"
    agent = scoped_default_agent(scope)

    {:ok,
     assign(socket,
       page_title: "Pepe · Learning",
       scope: scope,
       projects: Config.project_slugs(),
       new_project: false,
       learn_agent: agent,
       learn_nodes: Pepe.Learning.timeline(agent),
       auto?: agent && Reflect.auto?(agent),
       consolidating: false,
       editing: nil,
       pending: pending_writes()
     )}
  end

  # The picker only offers agents inside the selected scope, so the agent whose timeline
  # is shown has to come from that same list: picking the global default regardless would
  # render one agent in the dropdown and another one's memory right below it. Changing the
  # scope re-navigates to `/learn?scope=...` (see `set_scope/3`), which remounts this
  # LiveView, so resolving it here covers scope changes too.
  defp scoped_default_agent(scope) do
    names = scoped_agent_names(scope)
    default = Config.default_agent_name()

    cond do
      default in names -> default
      names != [] -> hd(names)
      true -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="learn" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="✦"
          title={gettext("Learning")}
          desc={gettext("What this agent has picked up: skills it can run and memory it saved, newest first. Click any item to read and edit it. \"Consolidate now\" has the agent tidy all of this, merging duplicates and dropping what is stale; it can delete things, so check the result. \"Nightly\" does the same pass on its own, once a night.")}
        >
          <div :if={!@editing} class="flex flex-wrap items-center gap-2">
            <button phx-click="consolidate_now" disabled={@consolidating || is_nil(@learn_agent)} class={btn_ghost()}>
              {if @consolidating, do: gettext("Consolidating..."), else: gettext("Consolidate now")}
            </button>
            <button phx-click="toggle_auto" disabled={is_nil(@learn_agent)} class={btn_ghost()}>
              {if @auto?, do: gettext("Nightly: on"), else: gettext("Nightly: off")}
            </button>
            <form id="learn-agent-picker" phx-change="pick_learn_agent" class="flex items-center gap-2">
              <label for="learn-agent" class="text-sm text-zinc-400">{gettext("Agent:")}</label>
              <select id="learn-agent" name="agent" class={[fld_sm(), "w-48"]}>
                <option :for={a <- scoped_agent_names(@scope)} value={a} selected={a == @learn_agent}>{a}</option>
              </select>
            </form>
          </div>
          <button :if={@editing} phx-click="learn_close" class={btn_ghost()}>&larr; {gettext("Back")}</button>
        </.view_header>

        <div :if={@editing} class="flex min-h-0 flex-1 flex-col gap-3 p-4 sm:p-6">
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

        <div :if={!@editing} class="flex-1 space-y-3 overflow-y-auto p-4 sm:p-6">
          <div :if={@pending != []} class="mb-4 rounded-xl border border-amber-800/50 bg-amber-950/20 p-3">
            <div class="mb-2 text-sm font-semibold text-amber-200">
              {ngettext("%{count} write awaiting your review", "%{count} writes awaiting your review", length(@pending))}
              <span class="ml-1 font-normal text-amber-200/60">{gettext("(staged by consolidation, not yet applied)")}</span>
            </div>
            <div :for={p <- @pending} class="flex items-start justify-between gap-3 rounded-lg px-2 py-1.5 hover:bg-amber-900/20">
              <div class="min-w-0">
                <div class="flex flex-wrap items-baseline gap-x-2 text-[15px]">
                  <span class="font-medium">{p.tool}</span>
                  <span :if={p.path} class="font-mono text-sm text-zinc-300">{p.path}</span>
                  <span class="text-sm text-zinc-500">{gettext("by %{agent}", agent: p.agent)}</span>
                </div>
                <div class={["truncate text-sm text-zinc-400", p.raw? && "font-mono"]}>{p.detail}</div>
              </div>
              <div class="flex shrink-0 flex-wrap gap-1">
                <button phx-click="approve_write" phx-value-id={p.id} class={btn_ghost()}>{gettext("Approve")}</button>
                <button phx-click="reject_write" phx-value-id={p.id} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>{gettext("Reject")}</button>
              </div>
            </div>
          </div>

          <button
            :for={n <- @learn_nodes}
            phx-click="learn_open"
            phx-value-kind={n.kind}
            phx-value-title={n.title}
            class={[card(), "flex w-full gap-3 text-left hover:bg-zinc-900"]}
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
     |> assign(pending: pending_writes(), learn_nodes: Pepe.Learning.timeline(socket.assigns.learn_agent))
     |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  def handle_event("reject_write", %{"id" => id}, socket) do
    Pepe.Approval.reject(id)
    {:noreply, socket |> assign(pending: pending_writes()) |> put_flash(:info, gettext("Rejected, nothing was written."))}
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

  # A staged write is stored as the raw tool call the agent made, whose arguments are a
  # JSON blob. Rendering that blob verbatim tells the person approving it nothing, so each
  # entry is flattened into what they actually need to judge it: the file it targets and a
  # plain-language line about the change. Anything that doesn't parse (or a tool with no
  # path) falls back to the raw arguments, shown monospaced.
  defp pending_writes do
    Enum.map(Pepe.Approval.list(), fn e ->
      {path, detail, raw?} = preview(e["tool"], get_in(e, ["tool_call", "function", "arguments"]))
      %{id: e["id"], tool: e["tool"], agent: e["agent"], path: path, detail: detail, raw?: raw?}
    end)
  end

  defp preview(tool, arguments) do
    raw = to_string(arguments || "")

    case Jason.decode(raw) do
      {:ok, %{} = args} -> {args["path"], describe(tool, args), false}
      _ -> {nil, peek(raw), true}
    end
  end

  defp describe("write_file", %{"content" => content}) when is_binary(content),
    do: gettext("Replaces the whole file with: %{peek}", peek: peek(content))

  defp describe("edit_file", %{"old_string" => old, "new_string" => new}) when is_binary(old) and is_binary(new),
    do: gettext("Replaces \"%{old}\" with \"%{new}\"", old: peek(old), new: peek(new))

  defp describe(_tool, args),
    do: args |> Map.drop(["path"]) |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{peek(v)}" end)

  # One readable line out of a possibly long, multi-line value.
  defp peek(value) when is_binary(value) do
    flat = value |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(flat) > 140, do: String.slice(flat, 0, 140) <> "...", else: flat
  end

  defp peek(value), do: value |> inspect() |> peek()

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
