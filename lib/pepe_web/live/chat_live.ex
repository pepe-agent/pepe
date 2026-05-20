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

  alias Pepe.Agent.GoalLoop
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.SessionTitles
  alias Pepe.Config
  alias Pepe.ModelSwitch
  alias Pepe.Permissions.Prompt
  alias Pepe.Session.Focus

  # How many of the most recent messages to render before "Load earlier messages".
  @window 40

  defp slash_commands do
    [
      {"/new", gettext("Start a fresh conversation")},
      {"/stop", gettext("Stop the current run")},
      {"/inline", gettext("Feed a message into the running turn - TEXT")},
      {"/goal", gettext("Pursue a goal until a reviewer approves - OBJECTIVE | SUCCESS CRITERION")},
      {"/retry", gettext("Redo the last answer")},
      {"/fork", gettext("Branch this conversation into a new one")},
      {"/name", gettext("Label this conversation in the sidebar - TEXT")},
      {"/usage", gettext("Show this month's spend and message count")},
      {"/compact", gettext("Summarize history to free up context")},
      {"/models", gettext("List models available to this company")},
      {"/model", gettext("Show or change the model - NAME [session|global]")}
    ]
  end

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3000, self(), :refresh_sessions)

    scope = params["scope"] || "all"

    {:ok,
     assign(socket,
       page_title: "Pepe · Chat",
       scope: scope,
       companies: Config.companies(),
       new_company: false,
       f_agent: "",
       f_channel: "",
       f_q: "",
       sessions: list_sessions(scope),
       selected: nil,
       agent: nil,
       messages: [],
       window: @window,
       streaming: "",
       running: false,
       activity: [],
       input: "",
       pending_perm: nil,
       focus: nil
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
    assigns = assign(assigns, :visible, filter_sessions(assigns.sessions, assigns.f_agent, assigns.f_channel, assigns.f_q))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="chat" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <div class="flex h-full min-w-0">
          <div class="flex w-80 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/30">
            <div class="border-b border-zinc-800 p-3">
              <button phx-click="new_chat" class="w-full rounded-lg bg-orange-600 px-3 py-2 text-[15px] font-medium transition hover:bg-orange-500">
                + {gettext("New chat")}
              </button>
              <p class="mt-2 px-1 text-xs leading-relaxed text-zinc-500">
                {gettext("Every conversation (web, Telegram, API and console) appears here.")}
              </p>
            </div>

            <form id="chat-filter" :if={@sessions != []} phx-change="filter_chats" class="space-y-2 border-b border-zinc-800 p-3">
              <input
                name="q"
                value={@f_q}
                autocomplete="off"
                phx-debounce="200"
                placeholder={gettext("Search conversations")}
                class="w-full rounded-lg border border-zinc-800 bg-zinc-900 px-2.5 py-1.5 text-sm text-zinc-200 placeholder:text-zinc-600"
              />
              <div class="grid grid-cols-2 gap-2">
                <select name="agent" class="rounded-lg border border-zinc-800 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-200">
                  <option value="">{gettext("All agents")}</option>
                  <option :for={a <- session_agents(@sessions)} value={a} selected={a == @f_agent}>{a}</option>
                </select>
                <select name="channel" class="rounded-lg border border-zinc-800 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-200">
                  <option value="">{gettext("All channels")}</option>
                  <option :for={c <- session_channels(@sessions)} value={c} selected={c == @f_channel}>{type_label(c)}</option>
                </select>
              </div>
            </form>

            <div class="flex-1 overflow-y-auto py-1">
              <div :for={{type, items} <- grouped(@visible)}>
                <div class="px-4 pb-1 pt-3 text-xs font-semibold uppercase tracking-wider text-zinc-600">
                  {type_label(type)} <span class="text-zinc-700">· {length(items)}</span>
                </div>
                <div :for={s <- items} class={["group mx-2 mb-0.5 flex items-center rounded-lg transition hover:bg-zinc-800/70", @selected == s.key && "bg-zinc-800"]}>
                  <button phx-click="select" phx-value-key={s.key} class="min-w-0 flex-1 px-3 py-2 text-left">
                    <div class="truncate text-[15px] font-medium">{s.title || session_suffix(s.key)}</div>
                    <div class="truncate text-sm text-zinc-500">{s.agent || "-"} · {gettext("%{count} turns", count: s.turns)}</div>
                  </button>
                  <button phx-click="delete" phx-value-key={s.key} data-confirm={gettext("Delete session %{key}?", key: s.key)} title={gettext("Delete session")}
                    class="px-3 py-2 text-zinc-600 opacity-0 transition hover:text-red-400 group-hover:opacity-100">✕</button>
                </div>
              </div>
              <p :if={@sessions == []} class="px-4 py-6 text-[15px] text-zinc-500">
                {gettext("No conversations yet. Start one with “New chat”.")}
              </p>
              <p :if={@sessions != [] and @visible == []} class="px-4 py-6 text-[15px] text-zinc-500">
                {gettext("No conversations match these filters.")}
              </p>
            </div>
          </div>

          <div :if={@selected} class="flex min-w-0 flex-1 flex-col">
            <header class="flex items-center justify-between border-b border-zinc-800 px-5 py-3">
              <div class="min-w-0 truncate">
                <div class="truncate font-medium">{SessionTitles.get(@selected) || session_suffix(@selected)}</div>
                <div class="truncate text-sm text-zinc-500">{@agent || "-"} · {@selected}</div>
              </div>
              <div class="flex gap-2">
                <button phx-click="reset" class={btn_ghost()}>{gettext("New")}</button>
                <button phx-click="stop" disabled={!@running} class={[btn_ghost(), "disabled:opacity-40"]}>{gettext("Stop")}</button>
              </div>
            </header>

            <.focus_panel :if={@focus} focus={@focus} />

            <div id="chat-scroll" phx-hook=".ChatScroll" class="flex-1 space-y-3 overflow-y-auto p-5">
              <div :if={@messages == [] and not @running} class="flex h-full items-center justify-center text-[15px] text-zinc-600">
                {gettext("Fresh conversation. Send a message to start.")}
              </div>
              <div :if={length(@messages) > @window} class="flex justify-center">
                <button phx-click="load_older" class={btn_ghost()}>{gettext("Load earlier messages")}</button>
              </div>
              <.bubble :for={m <- visible(@messages, @window)} role={m.role} content={m.content} />
              <.bubble :if={@running and @streaming != ""} role="assistant" content={@streaming} />
              <.activity :if={(@running or @activity != []) and !@pending_perm} running={@running} steps={@activity} />

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

              <form id="chat-compose" phx-submit="send" phx-change="type" class="flex gap-2">
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatScroll">
      export default {
        atBottom() {
          return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
        },
        toBottom() {
          this.el.scrollTop = this.el.scrollHeight
        },
        mounted() {
          this.stick = true
          this.toBottom()
        },
        beforeUpdate() {
          this.stick = this.atBottom()
        },
        updated() {
          if (this.stick) this.toBottom()
        }
      }
    </script>
    """
  end

  attr :focus, :map, required: true

  # A slim panel under the header showing the session's current goal and plan checklist.
  defp focus_panel(assigns) do
    ~H"""
    <div class="border-b border-zinc-800 bg-zinc-900/40 px-5 py-3 text-[15px]">
      <div :if={@focus.goal} class="flex items-start gap-2">
        <span class="mt-0.5 text-zinc-500">🎯</span>
        <div class="min-w-0">
          <span class="font-medium">{@focus.goal["objective"]}</span>
          <span class={["ml-2 rounded-full px-2 py-0.5 text-xs font-medium", goal_badge(@focus.goal["status"])]}>
            {@focus.goal["status"] || "active"}
          </span>
          <span :if={@focus.goal["attempt"]} class="ml-2 text-xs text-zinc-500">
            {gettext("attempt %{n}/%{max}", n: @focus.goal["attempt"], max: @focus.goal["max_attempts"])}
          </span>
          <%!-- The success criterion and the judge's last verdict: what makes this a
                goal loop rather than a note-to-self. --%>
          <div :if={@focus.goal["criteria"]} class="mt-1 text-sm text-zinc-500">
            {gettext("Done when:")} {@focus.goal["criteria"]}
          </div>
          <div :if={@focus.goal["verdict"]} class="mt-1 text-sm text-zinc-400">
            <span class="text-zinc-600">{gettext("Reviewer:")}</span> {@focus.goal["verdict"]}
          </div>
        </div>
      </div>
      <ul :if={is_list(@focus.plan) and @focus.plan != []} class={["space-y-0.5 text-sm", @focus.goal && "mt-2"]}>
        <li :for={s <- @focus.plan} class="flex items-center gap-2 text-zinc-400">
          <span class="w-4 text-center">{plan_box(s["status"])}</span>
          <span class={s["status"] == "done" && "text-zinc-600 line-through"}>{s["title"]}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp goal_badge("complete"), do: "bg-green-500/15 text-green-400"
  defp goal_badge("blocked"), do: "bg-red-500/15 text-red-400"
  defp goal_badge("paused"), do: "bg-zinc-600/30 text-zinc-400"
  defp goal_badge(_), do: "bg-orange-500/15 text-orange-300"

  defp plan_box("done"), do: "✅"
  defp plan_box("in_progress"), do: "⏳"
  defp plan_box(_), do: "▫️"

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

  attr :running, :boolean, required: true
  attr :steps, :list, required: true

  # A compact, transient "what I'm doing" strip - a spinner while running, the tool
  # steps below it. Shown during the run and for a couple seconds after (then cleared),
  # so machine chatter never lingers in the conversation but the answer isn't preceded
  # by a blank gap either.
  defp activity(assigns) do
    ~H"""
    <div class="max-w-2xl rounded-xl border border-zinc-800 bg-zinc-900/40 px-3.5 py-2.5">
      <div class="flex items-center gap-2 text-sm text-zinc-500">
        <span :if={@running} class="inline-block h-2 w-2 shrink-0 animate-pulse rounded-full bg-orange-500"></span>
        <span :if={!@running} class="text-emerald-500">✓</span>
        <span>{(@running && gettext("Working...")) || gettext("Done")}</span>
      </div>
      <div :for={step <- @steps} class="mt-1 flex items-center gap-2 text-sm text-zinc-500">
        <span class="text-amber-400/80">⚙</span>
        <span class="font-mono text-xs">{step}</span>
      </div>
    </div>
    """
  end

  defp bubble_class("user"), do: "ml-auto bg-orange-600"
  defp bubble_class("tool"), do: "bg-zinc-800/60 font-mono text-sm text-zinc-400"
  defp bubble_class("tool_call"), do: "bg-transparent px-0"
  defp bubble_class(_), do: "bg-zinc-800"

  ## events

  @impl true
  def handle_event("type", %{"text" => text}, socket), do: {:noreply, assign(socket, input: text)}

  def handle_event("load_older", _p, socket), do: {:noreply, assign(socket, window: socket.assigns.window + @window)}

  def handle_event("select", %{"key" => key}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat?chat=#{key}")}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    SessionSupervisor.terminate(key)
    SessionTitles.delete(key)
    socket = assign(socket, sessions: list_sessions(socket.assigns.scope))

    if socket.assigns.selected == key do
      unsubscribe(key)

      socket =
        assign(socket,
          selected: nil,
          agent: nil,
          messages: [],
          streaming: "",
          running: false,
          activity: []
        )

      {:noreply, push_patch(socket, to: ~p"/chat")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_chat", _params, socket) do
    agent = default_agent_for(socket.assigns.scope)
    key = "web:" <> Integer.to_string(System.unique_integer([:positive]))

    case agent && SessionSupervisor.ensure(key, agent) do
      {:ok, _pid} ->
        {:noreply, socket |> assign(sessions: list_sessions(socket.assigns.scope)) |> push_patch(to: ~p"/chat?chat=#{key}")}

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
         |> assign(streaming: "", running: true, activity: [], input: "")}

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
       activity: [],
       pending_perm: nil
     )
     |> put_flash(:info, gettext("🧠 New conversation started."))}
  end

  def handle_event("stop", _params, socket) do
    if socket.assigns.selected, do: Session.stop(socket.assigns.selected)
    {:noreply, assign(socket, running: false, streaming: "", activity: [])}
  end

  def handle_event("perm", %{"id" => id, "decision" => token}, socket) do
    # `id` comes over the socket and a client can send any string; `String.to_integer` would
    # raise and crash the LiveView, so parse leniently and ignore a malformed or stale one.
    with {id, ""} <- Integer.parse(to_string(id)),
         %{id: ^id, pid: pid} <- socket.assigns.pending_perm do
      send(pid, {:perm_reply, id, Prompt.from_token(token)})
      {:noreply, assign(socket, pending_perm: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("filter_chats", params, socket) do
    {:noreply,
     assign(socket,
       f_agent: params["agent"] || "",
       f_channel: params["channel"] || "",
       f_q: params["q"] || ""
     )}
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

  # The session named itself after its first exchange (Pepe.Agent.SessionTitles). It arrives
  # after the reply, on its own, so the sidebar has to be told rather than asked.
  def handle_info({:titled, _key, _title}, socket),
    do: {:noreply, assign(socket, sessions: list_sessions(socket.assigns.scope))}

  def handle_info({:compacted, key}, socket) do
    if key == socket.assigns.selected do
      # Replace the lingering "Compacting..." notice with a done one (which auto-dismisses).
      {:noreply,
       socket
       |> assign(messages: history(key))
       |> clear_flash()
       |> put_flash(:info, gettext("🧠 History compacted."))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_sessions, socket),
    do: {:noreply, assign(socket, sessions: list_sessions(socket.assigns.scope), focus: load_focus(socket.assigns.selected))}

  def handle_info(:clear_activity, socket) do
    # Only clear once the run is really over (a new run may have started meanwhile).
    if socket.assigns.running,
      do: {:noreply, socket},
      else: {:noreply, assign(socket, activity: [])}
  end

  defp apply_event({:assistant_delta, text}, socket),
    do: update(socket, :streaming, &(&1 <> text))

  defp apply_event({:tool_call, name, _args}, socket),
    do: update(socket, :activity, &(&1 ++ [gettext("Running %{tool}", tool: name)]))

  defp apply_event({:permission_request, id, name, requester}, socket),
    do: assign(socket, pending_perm: %{id: id, tool: name, pid: requester})

  # `:done` fires from inside the run task, before the session has absorbed the turn, so
  # the history read here can still be one turn behind. Show the answer right away
  # anyway, because waiting would leave the reader staring at a blank; `:committed`
  # below then reconciles against the session, which is the source of truth.
  defp apply_event({:done, content}, socket) do
    # Keep the activity strip briefly, then drop it - so the answer is already there to
    # read and only the machine chatter disappears (never a blank gap).
    Process.send_after(self(), :clear_activity, 2000)

    assign(socket,
      messages: ensure_reply(history(socket.assigns.selected), content),
      streaming: "",
      running: false,
      pending_perm: nil,
      sessions: list_sessions(socket.assigns.scope)
    )
  end

  # The turn is now in the session's state. Re-read it. This is what makes a goal loop's
  # retry turns appear: their answers land while the last message is already an assistant
  # one, so `ensure_reply` leaves the list alone and only this re-read picks them up.
  defp apply_event(:committed, %{assigns: %{selected: key}} = socket) when is_binary(key),
    do: assign(socket, messages: history(key))

  defp apply_event({:error, _reason}, socket) do
    socket
    |> assign(running: false, streaming: "", activity: [], pending_perm: nil)
    |> put_flash(:error, gettext("The run failed. Check the model connection."))
  end

  defp apply_event(_event, socket), do: socket

  # Never end blank (which reads as an error): if the turn produced no visible answer,
  # show the final content, or a small acknowledgement when it's genuinely empty.
  defp ensure_reply(messages, content) do
    case List.last(messages) do
      %{role: "assistant", content: c} when c != "" ->
        messages

      _ ->
        text = content |> to_string() |> String.trim()
        note = if text == "", do: gettext("✓ Done."), else: text
        messages ++ [%{role: "assistant", content: note}]
    end
  end

  ## session helpers

  defp open(socket, key) do
    unsubscribe(socket.assigns.selected)
    SessionSupervisor.ensure(key, Config.default_agent_name())
    Phoenix.PubSub.subscribe(Pepe.PubSub, topic(key))

    assign(socket,
      selected: key,
      agent: status(key).agent,
      messages: history(key),
      window: @window,
      streaming: "",
      running: false,
      activity: [],
      focus: load_focus(key)
    )
  end

  # Render only the most recent `window` messages (a long chat is slow to render all at
  # once); "Load earlier messages" widens the window on demand.
  defp visible(messages, window) when length(messages) <= window, do: messages
  defp visible(messages, window), do: Enum.take(messages, -window)

  # The session's current goal + plan (from the disposable store), for the focus panel.
  defp load_focus(nil), do: nil

  defp load_focus(key) do
    case {Focus.get_goal(key), Focus.get_plan(key)} do
      {nil, nil} -> nil
      {goal, plan} -> %{goal: goal, plan: plan}
    end
  end

  defp stream_reply(key, text) do
    {on_event, authorize} = session_callbacks(key)

    spawn(fn ->
      Session.chat(key, text, stream: true, on_event: on_event, authorize: authorize)
    end)
  end

  # Stream a run's events to this chat over PubSub, and route its permission prompts to
  # the operator. Shared by a normal turn and by a goal loop (whose attempts are just
  # turns, so they stream the same way).
  defp session_callbacks(key) do
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

    {on_event, authorize}
  end

  # `/goal <objective> | <success criterion>` - work, have an independent reviewer check
  # the result, retry until it passes or the attempt cap is hit. The panel above the
  # chat shows the criterion, the attempt count and the reviewer's last verdict.
  defp start_goal(socket, key, cmd) do
    parts =
      cmd
      |> String.replace_prefix("/goal", "")
      |> String.split("|", parts: 2)
      |> Enum.map(&String.trim/1)

    case parts do
      [objective, criteria] when objective != "" and criteria != "" ->
        {on_event, authorize} = session_callbacks(key)

        spawn(fn ->
          GoalLoop.run(key, objective, criteria, stream: true, on_event: on_event, authorize: authorize)
        end)

        socket
        |> assign(input: "", streaming: "", running: true, activity: [])
        |> put_flash(:info, gettext("Pursuing the goal until a reviewer approves it."))

      _ ->
        put_flash(socket, :error, gettext("Usage: /goal OBJECTIVE | SUCCESS CRITERION"))
    end
  end

  defp run_slash_command(socket, cmd), do: dispatch_slash(slash_name(cmd), socket, socket.assigns.selected, cmd)

  defp dispatch_slash(name, socket, key, _cmd) when name in ["/new", "/reset"], do: new_conversation(socket, key)
  defp dispatch_slash("/stop", socket, key, _cmd), do: stop_turn(socket, key)
  defp dispatch_slash("/inline", socket, key, cmd), do: inline_into_turn(socket, key, cmd)
  defp dispatch_slash("/goal", socket, key, cmd), do: start_goal(socket, key, cmd)
  defp dispatch_slash("/retry", socket, key, _cmd), do: retry_last(socket, key)
  defp dispatch_slash("/fork", socket, key, _cmd), do: fork_session(socket, key)
  defp dispatch_slash("/name", socket, key, cmd), do: label_session(socket, key, cmd)
  defp dispatch_slash("/compact", socket, key, _cmd), do: compact_session(socket, key)
  defp dispatch_slash("/models", socket, _key, _cmd), do: list_models(socket)
  defp dispatch_slash("/model", socket, key, cmd), do: change_model(socket, key, slash_args(cmd))

  defp dispatch_slash("/usage", socket, key, _cmd),
    do: socket |> assign(input: "") |> put_flash(:info, usage_line(key))

  defp dispatch_slash(_name, socket, _key, cmd),
    do: put_flash(socket, :error, gettext("Unknown command %{cmd}", cmd: cmd))

  defp new_conversation(socket, key) do
    Session.reset(key)

    socket
    |> assign(
      messages: history(key),
      streaming: "",
      running: false,
      activity: [],
      pending_perm: nil,
      input: ""
    )
    |> put_flash(:info, gettext("🧠 New conversation started."))
  end

  defp stop_turn(socket, key) do
    Session.stop(key)
    assign(socket, running: false, streaming: "", activity: [], input: "")
  end

  defp inline_into_turn(socket, key, cmd) do
    text = cmd |> String.replace_prefix("/inline", "") |> String.trim()

    flash =
      cond do
        text == "" -> {:error, gettext("Usage: /inline TEXT")}
        match?(:ok, Session.inline(key, text)) -> {:info, gettext("Fed into the running turn.")}
        true -> {:error, gettext("Nothing is running - send it as a normal message.")}
      end

    socket |> assign(input: "") |> put_flash(elem(flash, 0), elem(flash, 1))
  end

  defp label_session(socket, key, cmd) do
    title = cmd |> String.replace_prefix("/name", "") |> String.trim()
    Pepe.Agent.SessionTitles.set(key, title)

    flash =
      if title == "",
        do: gettext("Label cleared."),
        else: gettext("Labeled “%{title}”.", title: title)

    socket
    |> assign(input: "", sessions: list_sessions(socket.assigns.scope))
    |> put_flash(:info, flash)
  end

  defp compact_session(socket, key) do
    parent = self()

    Task.start(fn ->
      Session.compact(key)
      send(parent, {:compacted, key})
    end)

    socket |> assign(input: "") |> put_flash(:info, gettext("Compacting history..."))
  end

  defp list_models(socket) do
    text =
      case ModelSwitch.list_for(scope_company(socket.assigns.scope)) do
        [] -> gettext("No models are configured for this company.")
        models -> gettext("Available models:") <> " " <> Enum.map_join(models, ", ", & &1.name)
      end

    socket |> assign(input: "") |> put_flash(:info, text)
  end

  # Branch the current conversation into a fresh session seeded with its history, then
  # switch to it. The original stays live in the sidebar to return to. The `-fork`
  # suffix marks the branch in the session list.
  defp fork_session(socket, key) do
    new_key = "web:" <> Integer.to_string(System.unique_integer([:positive])) <> "-fork"

    case Session.fork(key, new_key) do
      {:ok, ^new_key} ->
        # Label the branch off the source so it's recognizable in the sidebar.
        parent = SessionTitles.get(key) || session_suffix(key)
        SessionTitles.set(new_key, gettext("%{name} (fork)", name: parent))

        socket
        |> assign(input: "", sessions: list_sessions(socket.assigns.scope))
        |> put_flash(:info, gettext("Branched into a new conversation. The original stays in the sidebar."))
        |> push_patch(to: ~p"/chat?chat=#{new_key}")

      _ ->
        put_flash(socket, :error, gettext("Couldn't branch this conversation."))
    end
  end

  # Redo the last answer: drop the last user turn (and its responses), then re-send the
  # same user message so the model tries again. No-op with a friendly note if there's
  # no user turn yet, or if a turn is already running.
  defp retry_last(socket, key) do
    cond do
      socket.assigns.running ->
        put_flash(socket, :error, gettext("Wait for the current turn to finish."))

      text = last_user_text(socket.assigns.messages) ->
        Session.undo(key)
        stream_reply(key, text)

        socket
        |> assign(
          messages: history(key) ++ [%{role: "user", content: text}],
          streaming: "",
          running: true,
          activity: [],
          input: ""
        )

      true ->
        put_flash(socket, :error, gettext("Nothing to retry yet."))
    end
  end

  defp last_user_text(messages) do
    messages |> Enum.reverse() |> Enum.find_value(fn m -> m.role == "user" && m.content end)
  end

  # This month's spend and message count for the company that owns this session's agent.
  defp usage_line(key) do
    company = key |> status() |> Map.get(:agent) |> Pepe.Company.of()
    cost = Pepe.Usage.format_cost(Pepe.Usage.month_to_date(company))
    count = Pepe.Usage.message_count_month_to_date(company)
    gettext("This month: %{cost} · %{count} messages", cost: cost, count: count)
  end

  defp slash?(text), do: String.starts_with?(text, "/")
  defp slash_name(text), do: text |> String.split(~r/\s+/, parts: 2) |> List.first()
  defp slash_args(text), do: text |> String.split(~r/\s+/, trim: true) |> tl()

  # The dashboard has no untrusted-participant tier - a logged-in operator always
  # gets `:global` permission (may change the model for everyone, or just this
  # tab) - so, unlike Telegram/webhooks, there's no `:none`/`:session`-only case
  # to gate here. The ask-flow (missing scope -> ask to confirm) still applies.
  defp change_model(socket, key, []) do
    s = status(key)
    socket |> assign(input: "") |> put_flash(:info, gettext("Current model: %{model}", model: s.model || gettext("(unset)")))
  end

  defp change_model(socket, key, [name]), do: ask_or_apply(socket, key, name, nil)
  defp change_model(socket, key, [name, scope]), do: ask_or_apply(socket, key, name, scope)

  defp change_model(socket, _key, _args),
    do: put_flash(socket, :error, gettext("Usage: /model NAME [session|global]"))

  defp ask_or_apply(socket, key, name, scope) do
    cond do
      is_nil(Config.get_model(name)) ->
        put_flash(socket, :error, gettext("Unknown model: %{name}", name: name))

      scope == "session" ->
        report_model_result(socket, ModelSwitch.apply(key, socket.assigns.agent, name, :session), name, "session")

      scope == "global" ->
        report_model_result(socket, ModelSwitch.apply(key, socket.assigns.agent, name, :global), name, "global")

      scope in [nil, ""] ->
        socket
        |> assign(input: "")
        |> put_flash(
          :info,
          gettext(
            "Change to %{name} for this conversation only, or for everyone? Reply /model %{name} session or /model %{name} global.",
            name: name
          )
        )

      true ->
        put_flash(socket, :error, gettext("Usage: /model NAME [session|global]"))
    end
  end

  defp report_model_result(socket, :ok, name, scope) do
    socket
    |> assign(input: "")
    |> put_flash(:info, gettext("Model set to %{name} (%{scope}).", name: name, scope: scope_label(scope)))
  end

  defp report_model_result(socket, {:error, :unknown_model}, name, _scope),
    do: put_flash(socket, :error, gettext("Unknown model: %{name}", name: name))

  defp report_model_result(socket, {:error, :unknown_agent}, _name, _scope),
    do: put_flash(socket, :error, gettext("There's no agent to set the model on."))

  defp scope_label("session"), do: gettext("this conversation only")
  defp scope_label("global"), do: gettext("everyone")

  defp scope_company(scope) when scope in [nil, "all", "root"], do: nil
  defp scope_company(scope), do: scope

  defp slash_matches(input) do
    if slash?(input),
      do: Enum.filter(slash_commands(), fn {cmd, _} -> String.starts_with?(cmd, input) end),
      else: []
  end

  # A default agent for the current scope: the company's own, else the global default.
  defp default_agent_for(scope) when scope in [nil, "all", "root"], do: Config.default_agent_name()
  defp default_agent_for(company), do: Config.default_agent_for(company) || Config.default_agent_name()

  defp list_sessions(scope) do
    live = MapSet.new(SessionSupervisor.list())
    persisted = SessionPersistence.all() |> Enum.map(&elem(&1, 0))

    (MapSet.to_list(live) ++ persisted)
    |> Enum.uniq()
    |> Enum.map(&session_card(&1, MapSet.member?(live, &1)))
    |> Enum.filter(&in_scope?(&1.agent, scope))
    |> Enum.sort_by(& &1.key)
  end

  defp session_card(key, true) do
    s = status(key)
    %{key: key, title: SessionTitles.get(key), type: session_type(key), agent: s.agent, model: s.model, turns: s.turns}
  end

  defp session_card(key, false) do
    case SessionPersistence.load(key) do
      {:ok, agent, messages, _pending} ->
        %{
          key: key,
          title: SessionTitles.get(key),
          type: session_type(key),
          agent: agent,
          model: model_of(agent),
          turns: Enum.count(messages, &(&1["role"] == "user"))
        }

      :error ->
        %{key: key, title: SessionTitles.get(key), type: session_type(key), agent: nil, model: nil, turns: 0}
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

  defp filter_sessions(sessions, f_agent, f_channel, f_q) do
    q = f_q |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(sessions, fn s ->
      (f_agent == "" or s.agent == f_agent) and
        (f_channel == "" or s.type == f_channel) and
        (q == "" or String.contains?(String.downcase(s.key), q) or
           String.contains?(String.downcase(to_string(s.agent)), q))
    end)
  end

  defp session_agents(sessions) do
    sessions |> Enum.map(& &1.agent) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()
  end

  defp session_channels(sessions) do
    sessions |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()
  end

  @type_order ~w(telegram widget web tui api)

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
  defp type_label("widget"), do: gettext("Widget")
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
