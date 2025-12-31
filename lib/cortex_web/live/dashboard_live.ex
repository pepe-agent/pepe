defmodule CortexWeb.DashboardLive do
  @moduledoc """
  The web dashboard: a live list of sessions on the left, a streaming chat panel on
  the right. Pick a session to read its history and talk to its agent; replies stream
  in via PubSub (the run broadcasts its lifecycle events to `"session:<key>"`).

  Risky tools run without prompting here for now (the dashboard is the owner's local
  surface); a web approval flow can be added later, like the Telegram one.
  """
  use CortexWeb, :live_view

  alias Cortex.Agent.Session
  alias Cortex.Agent.SessionPersistence
  alias Cortex.Agent.SessionSupervisor
  alias Cortex.Config

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3000, self(), :refresh_sessions)

    {:ok,
     assign(socket,
       page_title: "Cortex",
       sessions: list_sessions(),
       selected: nil,
       agent: nil,
       messages: [],
       streaming: "",
       running: false,
       input: ""
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-900 text-zinc-100">
      <aside class="flex w-72 flex-col border-r border-zinc-800">
        <div class="flex items-center gap-2 border-b border-zinc-800 px-4 py-3">
          <span class="text-xl">🧠</span>
          <span class="font-semibold">Cortex</span>
        </div>
        <button
          phx-click="new_chat"
          class="m-3 rounded bg-blue-600 px-3 py-2 text-sm font-medium hover:bg-blue-500"
        >
          + New chat
        </button>
        <div class="flex-1 overflow-y-auto">
          <div :for={{type, items} <- grouped(@sessions)}>
            <div class="px-4 pb-1 pt-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">
              {type_label(type)} <span class="text-zinc-600">· {length(items)}</span>
            </div>
            <div
              :for={s <- items}
              class={[
                "group flex items-center border-b border-zinc-800 hover:bg-zinc-800",
                @selected == s.key && "bg-zinc-800"
              ]}
            >
              <button
                phx-click="select"
                phx-value-key={s.key}
                class="min-w-0 flex-1 px-4 py-2 text-left"
              >
                <div class="truncate font-medium">{session_suffix(s.key)}</div>
                <div class="truncate text-xs text-zinc-400">
                  {s.agent || "—"} · {s.model || "—"} · {s.turns} turns
                </div>
              </button>
              <button
                phx-click="delete"
                phx-value-key={s.key}
                data-confirm={"Delete session #{s.key}?"}
                title="Delete session"
                class="px-3 py-2 text-zinc-600 opacity-0 hover:text-red-400 group-hover:opacity-100"
              >
                ✕
              </button>
            </div>
          </div>
          <p :if={@sessions == []} class="px-4 py-6 text-sm text-zinc-500">
            No sessions yet — start one.
          </p>
        </div>
      </aside>

      <main class="flex flex-1 flex-col">
        <div :if={@selected} class="flex h-full flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div class="truncate">
              <div class="font-medium">{@selected}</div>
              <div class="text-xs text-zinc-400">{@agent}</div>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="reset"
                class="rounded bg-zinc-700 px-3 py-1 text-xs hover:bg-zinc-600"
              >
                New
              </button>
              <button
                phx-click="stop"
                disabled={!@running}
                class="rounded bg-zinc-700 px-3 py-1 text-xs hover:bg-zinc-600 disabled:opacity-40"
              >
                Stop
              </button>
            </div>
          </header>

          <div class="flex-1 space-y-3 overflow-y-auto p-4">
            <.bubble :for={m <- @messages} role={m.role} content={m.content} />
            <.bubble :if={@running and @streaming != ""} role="assistant" content={@streaming} />
            <div :if={@running and @streaming == ""} class="text-sm text-zinc-500">…</div>
          </div>

          <form phx-submit="send" phx-change="type" class="flex gap-2 border-t border-zinc-800 p-3">
            <input
              name="text"
              value={@input}
              autocomplete="off"
              placeholder="Message…"
              class="flex-1 rounded bg-zinc-800 px-3 py-2 outline-none placeholder:text-zinc-500"
            />
            <button type="submit" class="rounded bg-blue-600 px-4 py-2 font-medium hover:bg-blue-500">
              Send
            </button>
          </form>
        </div>

        <div :if={!@selected} class="flex flex-1 items-center justify-center text-zinc-500">
          Select or start a session.
        </div>
      </main>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp bubble(assigns) do
    ~H"""
    <div class={["max-w-2xl whitespace-pre-wrap rounded-lg px-3 py-2 text-sm", bubble_class(@role)]}>
      <span :if={@role == "tool_call"} class="text-amber-400">⚙ {@content}</span>
      <span :if={@role != "tool_call"}>{@content}</span>
    </div>
    """
  end

  defp bubble_class("user"), do: "ml-auto bg-blue-600"
  defp bubble_class("tool"), do: "bg-zinc-800/60 font-mono text-xs text-zinc-400"
  defp bubble_class("tool_call"), do: "bg-transparent px-0"
  defp bubble_class(_), do: "bg-zinc-800"

  ###
  ### events
  ###

  @impl true
  def handle_event("type", %{"text" => text}, socket), do: {:noreply, assign(socket, input: text)}

  def handle_event("select", %{"key" => key}, socket) do
    {:noreply, open(socket, key)}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    SessionSupervisor.terminate(key)

    socket =
      if socket.assigns.selected == key do
        unsubscribe(key)
        assign(socket, selected: nil, agent: nil, messages: [], streaming: "", running: false)
      else
        socket
      end

    {:noreply, assign(socket, sessions: list_sessions())}
  end

  def handle_event("new_chat", _params, socket) do
    agent = Config.default_agent_name()
    key = "web:" <> Integer.to_string(System.unique_integer([:positive]))

    case agent && SessionSupervisor.ensure(key, agent) do
      {:ok, _pid} -> {:noreply, socket |> open(key) |> assign(sessions: list_sessions())}
      _ -> {:noreply, put_flash(socket, :error, "No default agent configured.")}
    end
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    if socket.assigns.selected && text != "" && not socket.assigns.running do
      stream_reply(socket.assigns.selected, text)

      {:noreply,
       socket
       |> update(:messages, &(&1 ++ [%{role: "user", content: text}]))
       |> assign(streaming: "", running: true, input: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns.selected, do: Session.reset(socket.assigns.selected)

    {:noreply,
     assign(socket, messages: history(socket.assigns.selected), streaming: "", running: false)}
  end

  def handle_event("stop", _params, socket) do
    if socket.assigns.selected, do: Session.stop(socket.assigns.selected)
    {:noreply, assign(socket, running: false, streaming: "")}
  end

  ###
  ### async run events
  ###

  @impl true
  def handle_info({:session_event, key, event}, socket) do
    if key == socket.assigns.selected do
      {:noreply, apply_event(event, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_sessions, socket) do
    {:noreply, assign(socket, sessions: list_sessions())}
  end

  defp apply_event({:assistant_delta, text}, socket),
    do: update(socket, :streaming, &(&1 <> text))

  defp apply_event({:tool_call, name, _args}, socket),
    do: update(socket, :messages, &(&1 ++ [%{role: "tool_call", content: name}]))

  defp apply_event({:done, _content}, socket) do
    assign(socket,
      messages: history(socket.assigns.selected),
      streaming: "",
      running: false,
      sessions: list_sessions()
    )
  end

  defp apply_event({:error, _reason}, socket) do
    socket
    |> assign(running: false, streaming: "")
    |> put_flash(:error, "The run failed. Check the model connection.")
  end

  defp apply_event(_event, socket), do: socket

  ###
  ### helpers
  ###

  # Open a session: make sure it's live in this node (loading from disk if it was
  # started elsewhere), subscribe to its events, and load its history.
  defp open(socket, key) do
    unsubscribe(socket.assigns.selected)
    SessionSupervisor.ensure(key, Config.default_agent_name())
    Phoenix.PubSub.subscribe(Cortex.PubSub, topic(key))

    assign(socket,
      selected: key,
      agent: status(key).agent,
      messages: history(key),
      streaming: "",
      running: false
    )
  end

  # Fire-and-forget the run; its events drive the UI over PubSub.
  defp stream_reply(key, text) do
    topic = topic(key)

    on_event = fn event ->
      Phoenix.PubSub.broadcast(Cortex.PubSub, topic, {:session_event, key, event})
    end

    # The session already exists and is bound to its agent, so talk to it directly.
    spawn(fn -> Session.chat(key, text, stream: true, on_event: on_event) end)
  end

  # Every session: the ones live in this node (from the Registry) plus any persisted
  # on disk by another surface (e.g. the console), so the dashboard is a unified view.
  defp list_sessions do
    live = MapSet.new(SessionSupervisor.list())
    persisted = SessionPersistence.all() |> Enum.map(&elem(&1, 0))

    (MapSet.to_list(live) ++ persisted)
    |> Enum.uniq()
    |> Enum.map(&session_card(&1, MapSet.member?(live, &1)))
    |> Enum.sort_by(& &1.key)
  end

  defp session_card(key, true) do
    s = status(key)
    %{key: key, type: session_type(key), agent: s.agent, model: s.model, turns: s.turns}
  end

  defp session_card(key, false) do
    case SessionPersistence.load(key) do
      {:ok, agent, messages} ->
        %{
          key: key,
          type: session_type(key),
          agent: agent,
          model: model_of(agent),
          turns: Enum.count(messages, &(&1["role"] == "user"))
        }

      :error ->
        %{key: key, type: session_type(key), agent: nil, model: nil, turns: 0}
    end
  end

  defp model_of(nil), do: nil

  defp model_of(agent_name) do
    with %{} = agent <- Config.get_agent(agent_name),
         %{model: model} <- Config.model_for_agent(agent) do
      model
    else
      _ -> nil
    end
  end

  # Group sessions by gateway type, in a stable display order (Telegram, Web, …).
  @type_order ~w(telegram web tui api)

  defp grouped(sessions) do
    sessions
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} -> Enum.find_index(@type_order, &(&1 == type)) || 99 end)
  end

  defp session_type(key) do
    case String.split(key, ":", parts: 2) do
      [prefix, _rest] -> prefix
      _ -> "other"
    end
  end

  defp session_suffix(key) do
    case String.split(key, ":", parts: 2) do
      [_prefix, rest] -> rest
      _ -> key
    end
  end

  defp type_label("telegram"), do: "Telegram"
  defp type_label("web"), do: "Web"
  defp type_label("tui"), do: "Console"
  defp type_label("api"), do: "API"
  defp type_label(other), do: String.capitalize(other)

  defp history(nil), do: []

  defp history(key) do
    key
    |> Session.history()
    # Show only the conversation — hide system + raw tool output (internal noise).
    |> Enum.reject(&(&1["role"] in ["system", "tool"]))
    |> Enum.map(&%{role: &1["role"], content: to_string(&1["content"] || "")})
    |> Enum.reject(&(&1.content == "" and &1.role == "assistant"))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp status(key) do
    Session.status(key)
  rescue
    _ -> %{agent: nil, model: nil, turns: 0}
  catch
    :exit, _ -> %{agent: nil, model: nil, turns: 0}
  end

  defp topic(key), do: "session:" <> key
  defp unsubscribe(nil), do: :ok
  defp unsubscribe(key), do: Phoenix.PubSub.unsubscribe(Cortex.PubSub, topic(key))
end
