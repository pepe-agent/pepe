defmodule PepeWeb.ChatLive do
  @moduledoc """
  Chat section: the session list beside a streaming conversation panel. Pick a session
  to read its history and talk to its agent; replies stream in over PubSub, and a risky
  tool asks for permission inline.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Permissions.Prompt

  defp slash_commands do
    [
      {"/new", gettext("Start a fresh conversation")},
      {"/stop", gettext("Stop the current run")},
      {"/compact", gettext("Summarize history to free up context")}
    ]
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3000, self(), :refresh_sessions)

    {:ok,
     assign(socket,
       page_title: "Pepe · Chat",
       scope: "all",
       companies: Config.companies(),
       new_company: false,
       sessions: list_sessions(),
       selected: nil,
       agent: nil,
       messages: [],
       streaming: "",
       running: false,
       input: "",
       pending_perm: nil
     )}
  end

  @impl true
  def handle_params(%{"chat" => key}, _uri, socket) when is_binary(key) and key != "" do
    if socket.assigns.selected == key,
      do: {:noreply, socket},
      else: {:noreply, open(socket, key)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="chat" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <div class="flex h-full min-w-0">
          <div class="flex w-72 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/30">
            <div class="border-b border-zinc-800 p-3">
              <button phx-click="new_chat" class="w-full rounded-lg bg-orange-600 px-3 py-2 text-[15px] font-medium transition hover:bg-orange-500">
                + {gettext("New chat")}
              </button>
              <p class="mt-2 px-1 text-xs leading-relaxed text-zinc-500">
                {gettext("Every conversation - web, Telegram, API and console - appears here.")}
              </p>
            </div>
            <div class="flex-1 overflow-y-auto py-1">
              <div :for={{type, items} <- grouped(@sessions)}>
                <div class="px-4 pb-1 pt-3 text-xs font-semibold uppercase tracking-wider text-zinc-600">
                  {type_label(type)} <span class="text-zinc-700">· {length(items)}</span>
                </div>
                <div :for={s <- items} class={["group mx-2 mb-0.5 flex items-center rounded-lg transition hover:bg-zinc-800/70", @selected == s.key && "bg-zinc-800"]}>
                  <button phx-click="select" phx-value-key={s.key} class="min-w-0 flex-1 px-3 py-2 text-left">
                    <div class="truncate text-[15px] font-medium">{session_suffix(s.key)}</div>
                    <div class="truncate text-sm text-zinc-500">{s.agent || "-"} · {gettext("%{count} turns", count: s.turns)}</div>
                  </button>
                  <button phx-click="delete" phx-value-key={s.key} data-confirm={gettext("Delete session %{key}?", key: s.key)} title={gettext("Delete session")}
                    class="px-3 py-2 text-zinc-600 opacity-0 transition hover:text-red-400 group-hover:opacity-100">✕</button>
                </div>
              </div>
              <p :if={@sessions == []} class="px-4 py-6 text-[15px] text-zinc-500">
                {gettext("No conversations yet. Start one with “New chat”.")}
              </p>
            </div>
          </div>

          <div :if={@selected} class="flex min-w-0 flex-1 flex-col">
            <header class="flex items-center justify-between border-b border-zinc-800 px-5 py-3">
              <div class="min-w-0 truncate">
                <div class="truncate font-medium">{session_suffix(@selected)}</div>
                <div class="truncate text-sm text-zinc-500">{@agent || "-"} · {@selected}</div>
              </div>
              <div class="flex gap-2">
                <button phx-click="reset" class={btn_ghost()}>{gettext("New")}</button>
                <button phx-click="stop" disabled={!@running} class={[btn_ghost(), "disabled:opacity-40"]}>{gettext("Stop")}</button>
              </div>
            </header>

            <div class="flex-1 space-y-3 overflow-y-auto p-5">
              <div :if={@messages == [] and not @running} class="flex h-full items-center justify-center text-[15px] text-zinc-600">
                {gettext("Fresh conversation - send a message to start.")}
              </div>
              <.bubble :for={m <- @messages} role={m.role} content={m.content} />
              <.bubble :if={@running and @streaming != ""} role="assistant" content={@streaming} />
              <div :if={@running and @streaming == "" and !@pending_perm} class="text-[15px] text-zinc-500">...</div>

              <div :if={@pending_perm} class="max-w-2xl rounded-xl border border-amber-600/60 bg-amber-950/30 p-3">
                <div class="mb-2 text-[15px]">
                  🔐 {gettext("Allow me to run the")} <code class="text-amber-300">{@pending_perm.tool}</code> {gettext("tool?")}
                </div>
                <div class="flex flex-wrap gap-2">
                  <button :for={d <- Prompt.options()} phx-click="perm" phx-value-id={@pending_perm.id} phx-value-decision={Prompt.token(d)} class={btn_ghost()}>
                    {Prompt.label(d)}
                  </button>
                </div>
              </div>
            </div>

            <div class="relative border-t border-zinc-800 p-3">
              <div :if={slash_matches(@input) != []} class="absolute bottom-full left-3 mb-2 w-72 overflow-hidden rounded-xl border border-zinc-700 bg-zinc-900 shadow-xl">
                <button :for={{cmd, desc} <- slash_matches(@input)} type="button" phx-click="run_slash" phx-value-cmd={cmd}
                  class="flex w-full items-baseline gap-2 px-3 py-2 text-left hover:bg-zinc-800">
                  <span class="font-mono text-[15px] text-orange-400">{cmd}</span>
                  <span class="text-sm text-zinc-500">{desc}</span>
                </button>
              </div>

              <form phx-submit="send" phx-change="type" class="flex gap-2">
                <input name="text" value={@input} autocomplete="off" placeholder={gettext("Message...  (type / for commands)")}
                  class="flex-1 rounded-lg border border-zinc-800 bg-zinc-900 px-3 py-2 outline-none transition placeholder:text-zinc-600 focus:border-orange-500 focus:ring-1 focus:ring-orange-500" />
                <button type="submit" class="rounded-lg bg-orange-600 px-5 py-2 font-medium transition hover:bg-orange-500">{gettext("Send")}</button>
              </form>
            </div>
          </div>

          <div :if={!@selected} class="flex flex-1 flex-col items-center justify-center gap-3 text-center">
            <div class="text-5xl opacity-40">💬</div>
            <div class="max-w-xs text-[15px] text-zinc-400">{gettext("Pick a conversation on the left, or start a new one to talk to your agent.")}</div>
            <button phx-click="new_chat" class={btn()}>+ {gettext("New chat")}</button>
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp bubble(assigns) do
    ~H"""
    <div class={["max-w-2xl whitespace-pre-wrap rounded-lg px-3 py-2 text-[15px] leading-relaxed", bubble_class(@role)]}>
      <span :if={@role == "tool_call"} class="text-amber-400">⚙ {@content}</span>
      <span :if={@role != "tool_call"}>{Phoenix.HTML.raw(format_md(@content))}</span>
    </div>
    """
  end

  defp format_md(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/\*\*(.+?)\*\*/s, ~S(<strong>\1</strong>))
    |> String.replace(
      ~r/`([^`\n]+)`/,
      ~S(<code class="rounded bg-black/30 px-1 py-0.5">\1</code>)
    )
  end

  defp bubble_class("user"), do: "ml-auto bg-orange-600"
  defp bubble_class("tool"), do: "bg-zinc-800/60 font-mono text-sm text-zinc-400"
  defp bubble_class("tool_call"), do: "bg-transparent px-0"
  defp bubble_class(_), do: "bg-zinc-800"

  ## events

  @impl true
  def handle_event("type", %{"text" => text}, socket), do: {:noreply, assign(socket, input: text)}

  def handle_event("select", %{"key" => key}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat?chat=#{key}")}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    SessionSupervisor.terminate(key)
    socket = assign(socket, sessions: list_sessions())

    if socket.assigns.selected == key do
      unsubscribe(key)

      socket =
        assign(socket, selected: nil, agent: nil, messages: [], streaming: "", running: false)

      {:noreply, push_patch(socket, to: ~p"/chat")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_chat", _params, socket) do
    agent = Config.default_agent_name()
    key = "web:" <> Integer.to_string(System.unique_integer([:positive]))

    case agent && SessionSupervisor.ensure(key, agent) do
      {:ok, _pid} ->
        {:noreply,
         socket |> assign(sessions: list_sessions()) |> push_patch(to: ~p"/chat?chat=#{key}")}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("No default agent configured."))}
    end
  end

  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      socket.assigns.selected && slash?(text) ->
        {:noreply, run_slash_command(socket, text)}

      socket.assigns.selected && text != "" && not socket.assigns.running ->
        stream_reply(socket.assigns.selected, text)

        {:noreply,
         socket
         |> update(:messages, &(&1 ++ [%{role: "user", content: text}]))
         |> assign(streaming: "", running: true, input: "")}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("run_slash", %{"cmd" => cmd}, socket) do
    if socket.assigns.selected,
      do: {:noreply, run_slash_command(socket, cmd)},
      else: {:noreply, socket}
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns.selected, do: Session.reset(socket.assigns.selected)

    {:noreply,
     socket
     |> assign(
       messages: history(socket.assigns.selected),
       streaming: "",
       running: false,
       pending_perm: nil
     )
     |> put_flash(:info, gettext("🧠 New conversation started."))}
  end

  def handle_event("stop", _params, socket) do
    if socket.assigns.selected, do: Session.stop(socket.assigns.selected)
    {:noreply, assign(socket, running: false, streaming: "")}
  end

  def handle_event("perm", %{"id" => id, "decision" => token}, socket) do
    id = String.to_integer(id)

    case socket.assigns.pending_perm do
      %{id: ^id, pid: pid} ->
        send(pid, {:perm_reply, id, Prompt.from_token(token)})
        {:noreply, assign(socket, pending_perm: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/chat")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  ## async run events

  @impl true
  def handle_info({:session_event, key, event}, socket) do
    if key == socket.assigns.selected,
      do: {:noreply, apply_event(event, socket)},
      else: {:noreply, socket}
  end

  def handle_info({:compacted, key}, socket) do
    if key == socket.assigns.selected,
      do: {:noreply, assign(socket, messages: history(key))},
      else: {:noreply, socket}
  end

  def handle_info(:refresh_sessions, socket),
    do: {:noreply, assign(socket, sessions: list_sessions())}

  defp apply_event({:assistant_delta, text}, socket),
    do: update(socket, :streaming, &(&1 <> text))

  defp apply_event({:tool_call, name, _args}, socket),
    do: update(socket, :messages, &(&1 ++ [%{role: "tool_call", content: name}]))

  defp apply_event({:permission_request, id, name, requester}, socket),
    do: assign(socket, pending_perm: %{id: id, tool: name, pid: requester})

  defp apply_event({:done, _content}, socket) do
    assign(socket,
      messages: history(socket.assigns.selected),
      streaming: "",
      running: false,
      pending_perm: nil,
      sessions: list_sessions()
    )
  end

  defp apply_event({:error, _reason}, socket) do
    socket
    |> assign(running: false, streaming: "", pending_perm: nil)
    |> put_flash(:error, gettext("The run failed. Check the model connection."))
  end

  defp apply_event(_event, socket), do: socket

  ## session helpers

  defp open(socket, key) do
    unsubscribe(socket.assigns.selected)
    SessionSupervisor.ensure(key, Config.default_agent_name())
    Phoenix.PubSub.subscribe(Pepe.PubSub, topic(key))

    assign(socket,
      selected: key,
      agent: status(key).agent,
      messages: history(key),
      streaming: "",
      running: false
    )
  end

  defp stream_reply(key, text) do
    topic = topic(key)

    on_event = fn event ->
      Phoenix.PubSub.broadcast(Pepe.PubSub, topic, {:session_event, key, event})
    end

    authorize = fn name, _args, _ctx ->
      id = System.unique_integer([:positive])
      requester = self()

      Phoenix.PubSub.broadcast(
        Pepe.PubSub,
        topic,
        {:session_event, key, {:permission_request, id, name, requester}}
      )

      receive do
        {:perm_reply, ^id, decision} -> decision
      after
        120_000 -> :deny
      end
    end

    spawn(fn ->
      Session.chat(key, text, stream: true, on_event: on_event, authorize: authorize)
    end)
  end

  defp run_slash_command(socket, cmd) do
    key = socket.assigns.selected

    case slash_name(cmd) do
      c when c in ["/new", "/reset"] ->
        Session.reset(key)

        socket
        |> assign(
          messages: history(key),
          streaming: "",
          running: false,
          pending_perm: nil,
          input: ""
        )
        |> put_flash(:info, gettext("🧠 New conversation started."))

      "/stop" ->
        Session.stop(key)
        assign(socket, running: false, streaming: "", input: "")

      "/compact" ->
        parent = self()

        Task.start(fn ->
          Session.compact(key)
          send(parent, {:compacted, key})
        end)

        socket |> assign(input: "") |> put_flash(:info, gettext("Compacting history..."))

      _ ->
        put_flash(socket, :error, gettext("Unknown command %{cmd}", cmd: cmd))
    end
  end

  defp slash?(text), do: String.starts_with?(text, "/")
  defp slash_name(text), do: text |> String.split(~r/\s+/, parts: 2) |> List.first()

  defp slash_matches(input) do
    if slash?(input),
      do: Enum.filter(slash_commands(), fn {cmd, _} -> String.starts_with?(cmd, input) end),
      else: []
  end

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

  defp type_label("telegram"), do: gettext("Telegram")
  defp type_label("web"), do: gettext("Web")
  defp type_label("tui"), do: gettext("Console")
  defp type_label("api"), do: gettext("API")
  defp type_label(other), do: String.capitalize(other)

  defp history(nil), do: []

  defp history(key) do
    key
    |> Session.history()
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
  defp unsubscribe(key), do: Phoenix.PubSub.unsubscribe(Pepe.PubSub, topic(key))
end
