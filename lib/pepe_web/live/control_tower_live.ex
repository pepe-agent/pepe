defmodule PepeWeb.ControlTowerLive do
  @moduledoc """
  Control tower: every live session, on one screen, across every channel at once - the
  view `/chat` doesn't have, since it always shows exactly one conversation. Polls
  `Pepe.Agent.SessionSupervisor.list/0` (the same registry `/chat`'s sidebar and
  `/overview`'s live-session count already read) rather than adding a new PubSub
  channel: a control tower's whole reason to exist is seeing what's live *right now*,
  and a few hundred milliseconds of staleness on a 3s poll costs nothing next to that.

  Deliberately does not duplicate `/traces`' "group by conversation" cost/token view -
  that reads finished runs from disk and answers "what did this cost", a different
  question from "what's happening right now". A session here can be jumped into (opens
  it in `/chat`) or interrupted (`Stop`, for one stuck mid-turn) but its history and
  spend live where they always have.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.SessionTitles
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3000, self(), :refresh)

    scope = params["scope"] || "all"

    {:ok,
     assign(socket,
       page_title: "Pepe · Control tower",
       scope: scope,
       projects: Config.project_slugs(),
       new_project: false,
       f_agent: "",
       f_channel: "",
       f_q: "",
       sessions: live_sessions(scope)
     )}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign(socket, sessions: live_sessions(socket.assigns.scope))}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, filter_sessions(assigns.sessions, assigns.f_agent, assigns.f_channel, assigns.f_q))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="tower" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🛰️"
          title={gettext("Control tower")}
          desc={gettext("Every live session, across every channel, on one screen. Jump into one or stop it, right from here.")}
        />
        <div class="flex-1 space-y-4 overflow-y-auto p-6">
          <div class="flex flex-wrap gap-3">
            <.tile label={gettext("Live sessions")} value={length(@sessions)} />
            <.tile label={gettext("Running now")} value={Enum.count(@sessions, & &1.running)} accent="text-orange-400" />
            <.tile :for={{type, list} <- channel_breakdown(@sessions)} label={type_label(type)} value={length(list)} />
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <form phx-change="filter" class="flex flex-wrap items-center gap-2">
              <input type="text" name="q" value={@f_q} placeholder={gettext("Search key or agent...")} class={[fld(), "w-64"]} />
              <select name="agent" class={fld()}>
                <option value="">{gettext("All agents")}</option>
                <option :for={a <- session_agents(@sessions)} value={a} selected={@f_agent == a}>{a}</option>
              </select>
              <select name="channel" class={fld()}>
                <option value="">{gettext("All channels")}</option>
                <option :for={c <- session_channels(@sessions)} value={c} selected={@f_channel == c}>{type_label(c)}</option>
              </select>
            </form>
          </div>

          <div :if={@sessions == []} class="text-[15px] text-zinc-500">
            {gettext("Nothing live right now. A session appears here the moment someone starts one, on any channel.")}
          </div>

          <div :if={@sessions != [] and @visible == []} class="text-[15px] text-zinc-500">
            {gettext("No live session matches this filter.")}
          </div>

          <div :if={@visible != []} class="overflow-x-auto rounded-xl border border-zinc-800">
            <table class="w-full text-left text-sm">
              <thead class="bg-zinc-900/60 text-xs uppercase tracking-wider text-zinc-500">
                <tr>
                  <th class="px-4 py-2.5"></th>
                  <th class="px-4 py-2.5">{gettext("Channel")}</th>
                  <th class="px-4 py-2.5">{gettext("Session")}</th>
                  <th class="px-4 py-2.5">{gettext("Agent")}</th>
                  <th class="px-4 py-2.5">{gettext("Model")}</th>
                  <th class="px-4 py-2.5">{gettext("Turns")}</th>
                  <th class="px-4 py-2.5"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- sort_sessions(@visible)} class="border-t border-zinc-800/70 hover:bg-zinc-900/40">
                  <td class="px-4 py-2.5">
                    <span :if={s.running} class="inline-block h-2 w-2 rounded-full bg-orange-500" title={gettext("Running now")}></span>
                  </td>
                  <td class="px-4 py-2.5">
                    <span class="rounded bg-zinc-800 px-1.5 py-0.5 text-xs text-zinc-300">{type_label(s.type)}</span>
                  </td>
                  <td class="px-4 py-2.5">
                    <div class="max-w-xs truncate font-medium">{s.title || s.key}</div>
                    <div :if={s.title} class="max-w-xs truncate font-mono text-xs text-zinc-600">{s.key}</div>
                  </td>
                  <td class="px-4 py-2.5 text-zinc-300">{s.agent || "-"}</td>
                  <td class="px-4 py-2.5 text-zinc-400">{s.model || "-"}</td>
                  <td class="px-4 py-2.5 text-zinc-400">{s.turns}</td>
                  <td class="px-4 py-2.5">
                    <div class="flex justify-end gap-1.5">
                      <.link navigate={~p"/chat?chat=#{s.key}&scope=#{@scope}"} class={btn_ghost()}>{gettext("Open")}</.link>
                      <button :if={s.running} phx-click="stop_session" phx-value-key={s.key} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>
                        {gettext("Stop")}
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, assign(socket, f_agent: params["agent"] || "", f_channel: params["channel"] || "", f_q: params["q"] || "")}
  end

  def handle_event("stop_session", %{"key" => key}, socket) do
    Session.stop(key)
    {:noreply, assign(socket, sessions: live_sessions(socket.assigns.scope))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/tower")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: "text-zinc-100"

  defp tile(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-800 bg-zinc-900/50 px-4 py-3">
      <div class={["text-2xl font-bold", @accent]}>{@value}</div>
      <div class="text-xs uppercase tracking-wider text-zinc-500">{@label}</div>
    </div>
    """
  end

  # `SessionSupervisor.list/0` is a live snapshot; a key can disappear between reading it
  # and calling into it (the session finished and idled out), so every read is guarded -
  # same rescue/catch shape `PepeWeb.OverviewLive.session_agent/1` and `ChatLive`'s own
  # `status/1` helper already use for exactly this race.
  defp live_sessions(scope) do
    SessionSupervisor.list()
    |> Enum.map(&session_row/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&in_scope?(&1.agent, scope))
  end

  defp session_row(key) do
    s = Session.status(key)
    %{key: key, title: SessionTitles.get(key), type: session_type(key), agent: s.agent, model: s.model, turns: s.turns, running: s.running}
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp sort_sessions(sessions), do: Enum.sort_by(sessions, &{!&1.running, &1.key})

  defp filter_sessions(sessions, f_agent, f_channel, f_q) do
    q = f_q |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(sessions, fn s ->
      (f_agent == "" or s.agent == f_agent) and
        (f_channel == "" or s.type == f_channel) and
        (q == "" or String.contains?(String.downcase(s.key), q) or
           String.contains?(String.downcase(to_string(s.agent)), q))
    end)
  end

  defp session_agents(sessions), do: sessions |> Enum.map(& &1.agent) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()
  defp session_channels(sessions), do: sessions |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

  defp channel_breakdown(sessions) do
    sessions |> Enum.group_by(& &1.type) |> Enum.sort_by(fn {type, list} -> {-length(list), type} end)
  end

  defp session_type(key) do
    case String.split(key, ":", parts: 2) do
      [prefix, _rest] -> prefix
      _ -> "other"
    end
  end

  defp type_label("telegram"), do: gettext("Telegram")
  defp type_label("widget"), do: gettext("Widget")
  defp type_label("web"), do: gettext("Web")
  defp type_label("tui"), do: gettext("Console")
  defp type_label("api"), do: gettext("API")
  defp type_label("board"), do: gettext("Board")
  defp type_label("cli-goal"), do: gettext("Goal (CLI)")
  defp type_label(other), do: String.capitalize(other)
end
