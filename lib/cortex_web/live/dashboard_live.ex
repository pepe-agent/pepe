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
       view: :chat,
       sessions: list_sessions(),
       selected: nil,
       agent: nil,
       messages: [],
       streaming: "",
       running: false,
       input: "",
       learn_agent: Config.default_agent_name(),
       learn_nodes: [],
       crons: Config.crons(),
       cron_open: nil,
       bots: Config.telegram_bots()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-900 text-zinc-100">
      <aside class="flex w-72 flex-col border-r border-zinc-800">
        <div class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
          <div class="flex items-center gap-2">
            <span class="text-xl">🧠</span>
            <span class="font-semibold">Cortex</span>
          </div>
          <div class="flex overflow-hidden rounded bg-zinc-800 text-xs">
            <button
              phx-click="view"
              phx-value-to="chat"
              class={["px-3 py-1", @view == :chat && "bg-blue-600"]}
            >
              Chat
            </button>
            <button
              phx-click="view"
              phx-value-to="learn"
              class={["px-3 py-1", @view == :learn && "bg-blue-600"]}
            >
              Learn
            </button>
            <button
              phx-click="view"
              phx-value-to="cron"
              class={["px-3 py-1", @view == :cron && "bg-blue-600"]}
            >
              Cron
            </button>
            <button
              phx-click="view"
              phx-value-to="bots"
              class={["px-3 py-1", @view == :bots && "bg-blue-600"]}
            >
              Bots
            </button>
          </div>
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
        <div :if={@view == :learn} class="flex h-full flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">✦ TimeLearn</div>
              <div class="text-xs text-zinc-400">what the agent has learned, newest first</div>
            </div>
            <form phx-change="pick_learn_agent">
              <select name="agent" class="rounded bg-zinc-800 px-2 py-1 text-sm outline-none">
                <option :for={a <- agent_names()} value={a} selected={a == @learn_agent}>{a}</option>
              </select>
            </form>
          </header>
          <div class="flex-1 space-y-4 overflow-y-auto p-4">
            <div :for={n <- @learn_nodes} class="flex gap-3">
              <span class="text-lg">{learn_icon(n.kind)}</span>
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class="font-medium">{n.title}</span>
                  <span class="rounded bg-zinc-800 px-1.5 text-xs text-zinc-400">{n.source}</span>
                  <span class="text-xs text-zinc-500">{learn_date(n.at)}</span>
                </div>
                <div class="truncate text-sm text-zinc-400">{n.summary}</div>
              </div>
            </div>
            <p :if={@learn_nodes == []} class="text-sm text-zinc-500">Nothing learned yet.</p>
          </div>
        </div>

        <div :if={@view == :cron} class="flex h-full flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🕒 Scheduled tasks</div>
              <div class="text-xs text-zinc-400">recurring agent jobs · fire while the server runs</div>
            </div>
          </header>
          <div class="flex-1 space-y-4 overflow-y-auto p-4">
            <div
              :for={c <- @crons}
              class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3"
            >
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <span class="font-medium">{c.name}</span>
                  <span class={["ml-2 rounded px-1.5 text-xs", c.enabled && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                    {(c.enabled && "enabled") || "disabled"}
                  </span>
                </div>
                <div class="flex shrink-0 gap-1 text-xs">
                  <button phx-click="cron_run" phx-value-id={c.id} class="rounded bg-blue-600 px-2 py-1 hover:bg-blue-500">
                    Run now
                  </button>
                  <button phx-click="cron_toggle" phx-value-id={c.id} class="rounded bg-zinc-700 px-2 py-1 hover:bg-zinc-600">
                    {(c.enabled && "Disable") || "Enable"}
                  </button>
                  <button
                    phx-click="cron_remove"
                    phx-value-id={c.id}
                    data-confirm={"Remove scheduled task #{c.name}?"}
                    class="rounded bg-zinc-700 px-2 py-1 text-red-300 hover:bg-zinc-600"
                  >
                    ✕
                  </button>
                </div>
              </div>
              <div class="mt-1 text-xs text-zinc-400">
                <code>{c.schedule}</code> · {c.timezone} · next {cron_next(c)}
              </div>
              <div class="text-xs text-zinc-500">
                {c.agent}{model_suffix(c.model)} · → {deliver_label(c.deliver)}
              </div>
              <details class="mt-1">
                <summary class="cursor-pointer text-xs text-zinc-500">prompt & last runs</summary>
                <pre class="mt-1 whitespace-pre-wrap rounded bg-zinc-900 p-2 text-xs text-zinc-300">{c.prompt}</pre>
                <div :for={e <- cron_history(c.id)} class="mt-1 text-xs text-zinc-400">
                  {(e["ok"] && "✅") || "⚠️"} {learn_date(e["at"])} · {e["source"]}
                  <span class="text-zinc-500">— {String.slice(to_string(e["output"]), 0, 120)}</span>
                </div>
              </details>
            </div>
            <p :if={@crons == []} class="text-sm text-zinc-500">No scheduled tasks yet — create one below.</p>

            <form phx-submit="cron_create" class="space-y-2 rounded-lg border border-zinc-800 p-3">
              <div class="text-sm font-medium">+ New scheduled task</div>
              <input name="name" placeholder="Name (e.g. Daily XML check)" required
                class="w-full rounded bg-zinc-800 px-2 py-1 text-sm outline-none" />
              <textarea name="prompt" rows="3" required
                placeholder="What to do each run — self-contained (no chat memory)"
                class="w-full rounded bg-zinc-800 px-2 py-1 text-sm outline-none"></textarea>
              <div class="flex gap-2">
                <input name="schedule" placeholder="0 8 * * *" required
                  class="flex-1 rounded bg-zinc-800 px-2 py-1 font-mono text-sm outline-none" />
                <input name="timezone" value={Config.default_timezone()}
                  class="flex-1 rounded bg-zinc-800 px-2 py-1 text-sm outline-none" />
              </div>
              <div class="flex gap-2">
                <select name="agent" class="flex-1 rounded bg-zinc-800 px-2 py-1 text-sm outline-none">
                  <option :for={a <- agent_names()} value={a}>{a}</option>
                </select>
                <select name="model" class="flex-1 rounded bg-zinc-800 px-2 py-1 text-sm outline-none">
                  <option value="">agent default model</option>
                  <option :for={m <- model_names()} value={m}>{m}</option>
                </select>
                <select name="deliver" class="flex-1 rounded bg-zinc-800 px-2 py-1 text-sm outline-none">
                  <option value="none">Don't send anywhere</option>
                  <option :for={t <- deliver_targets(@sessions)} value={t}>{deliver_label(t)}</option>
                </select>
              </div>
              <div class="text-xs text-zinc-500">
                Schedule is a 5-field cron expression. Timezone is any IANA name.
              </div>
              <button type="submit" class="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium hover:bg-blue-500">
                Create task
              </button>
            </form>
          </div>
        </div>

        <div :if={@view == :bots} class="flex h-full flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🤖 Telegram bots</div>
              <div class="text-xs text-zinc-400">
                one poller per bot, each bound to an agent · changes apply live
              </div>
            </div>
          </header>
          <div class="flex-1 space-y-4 overflow-y-auto p-4">
            <div :for={b <- @bots} class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <span class="font-medium">{b["name"]}</span>
                  <span class={["ml-2 rounded px-1.5 text-xs", bot_active?(b) && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                    {(bot_active?(b) && "active") || "inactive"}
                  </span>
                </div>
                <button
                  :if={b["name"] != "default"}
                  phx-click="bot_remove"
                  phx-value-name={b["name"]}
                  data-confirm={"Remove bot #{b["name"]}?"}
                  class="rounded bg-zinc-700 px-2 py-1 text-xs text-red-300 hover:bg-zinc-600"
                >
                  ✕
                </button>
              </div>
              <div class="mt-1 text-xs text-zinc-400">agent: {b["agent"] || "(default)"}</div>
              <div class="text-xs text-zinc-500">token: {token_hint(b["bot_token"])}</div>
            </div>
            <p :if={@bots == []} class="text-sm text-zinc-500">
              No bots yet. The default bot is set via <code>mix cortex gateway telegram setup</code>.
            </p>

            <form phx-submit="bot_add" class="space-y-2 rounded-lg border border-zinc-800 p-3">
              <div class="text-sm font-medium">+ Add a bot</div>
              <input name="name" placeholder="Name (e.g. sales)" required
                class="w-full rounded bg-zinc-800 px-2 py-1 text-sm outline-none" />
              <input name="token" placeholder="Bot token from @BotFather (or ${ENV_VAR})" required
                class="w-full rounded bg-zinc-800 px-2 py-1 text-sm outline-none" />
              <select name="agent" class="w-full rounded bg-zinc-800 px-2 py-1 text-sm outline-none">
                <option value="">default agent</option>
                <option :for={a <- agent_names()} value={a}>{a}</option>
              </select>
              <button type="submit" class="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium hover:bg-blue-500">
                Add bot
              </button>
            </form>
          </div>
        </div>

        <div :if={@view == :chat and @selected} class="flex h-full flex-col">
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

        <div
          :if={@view == :chat and !@selected}
          class="flex flex-1 items-center justify-center text-zinc-500"
        >
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

  defp agent_names, do: Config.agents() |> Enum.map(& &1.name) |> Enum.sort()
  defp model_names, do: Config.models() |> Enum.map(& &1.name) |> Enum.sort()

  # Next fire time of a cron, formatted, or "—".
  defp cron_next(cron) do
    case Cortex.Cron.next_run(cron) do
      nil -> "—"
      dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M %Z")
    end
  end

  defp cron_history(id), do: Cortex.Cron.Log.tail(id, 3)

  defp model_suffix(nil), do: ""
  defp model_suffix(model), do: " · #{model}"

  defp deliver_label("none"), do: "not sent"
  defp deliver_label("telegram:" <> id), do: "Telegram #{id}"
  defp deliver_label(other), do: other

  # Delivery targets offered in the form: the known Telegram chats (from sessions).
  defp deliver_targets(sessions) do
    sessions
    |> Enum.map(& &1.key)
    |> Enum.filter(&String.starts_with?(&1, "telegram:"))
    |> Enum.uniq()
  end

  defp blank(nil), do: nil
  defp blank(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank(v), do: v

  defp bot_active?(bot), do: Cortex.Gateways.Telegram.bot_active?(bot)

  defp reject_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  # Apply bot changes to the running pollers (we're inside the serve process).
  defp reload_gateways do
    Cortex.Gateways.Supervisor.reload_telegram()
  rescue
    _ -> :ok
  end

  defp token_hint(nil), do: "(none)"
  defp token_hint("${" <> _ = env), do: env
  defp token_hint(t), do: String.slice(to_string(t), 0, 6) <> "…"

  # A readable, unique cron id derived from its name.
  defp new_cron_id(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    base = if base == "", do: "task", else: base
    taken = Enum.map(Config.crons(), & &1.id)

    if base not in taken do
      base
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n -> if "#{base}-#{n}" not in taken, do: "#{base}-#{n}" end)
    end
  end

  defp learn_icon(:skill), do: "🧠"
  defp learn_icon(_memory), do: "📝"

  defp learn_date(0), do: "—"

  defp learn_date(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "—"
    end
  end

  defp bubble_class("user"), do: "ml-auto bg-blue-600"
  defp bubble_class("tool"), do: "bg-zinc-800/60 font-mono text-xs text-zinc-400"
  defp bubble_class("tool_call"), do: "bg-transparent px-0"
  defp bubble_class(_), do: "bg-zinc-800"

  ###
  ### events
  ###

  @impl true
  def handle_event("view", %{"to" => "learn"}, socket) do
    {:noreply,
     assign(socket,
       view: :learn,
       learn_nodes: Cortex.Learning.timeline(socket.assigns.learn_agent)
     )}
  end

  def handle_event("view", %{"to" => "cron"}, socket) do
    {:noreply, assign(socket, view: :cron, crons: Config.crons())}
  end

  def handle_event("view", %{"to" => "bots"}, socket) do
    {:noreply, assign(socket, view: :bots, bots: Config.telegram_bots())}
  end

  def handle_event("view", %{"to" => _chat}, socket), do: {:noreply, assign(socket, view: :chat)}

  def handle_event("bot_add", %{"name" => name, "token" => token} = params, socket) do
    name = String.trim(name)

    cond do
      name in ["", "default"] ->
        {:noreply, put_flash(socket, :error, "Pick a name other than \"default\".")}

      blank(token) == nil ->
        {:noreply, put_flash(socket, :error, "A bot token is required.")}

      true ->
        map = %{"bot_token" => token, "agent" => blank(params["agent"])}
        Config.put_telegram_bot(name, reject_nil(map))
        reload_gateways()

        {:noreply,
         socket |> assign(bots: Config.telegram_bots()) |> put_flash(:info, "Bot #{name} added.")}
    end
  end

  def handle_event("bot_remove", %{"name" => name}, socket) do
    Config.delete_telegram_bot(name)
    reload_gateways()
    {:noreply, assign(socket, bots: Config.telegram_bots())}
  end

  def handle_event("cron_run", %{"id" => id}, socket) do
    case Config.get_cron(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Task not found.")}

      cron ->
        # Fire off the main-loop path; the run can take a while, so don't block LiveView.
        Task.start(fn -> Cortex.Cron.run(cron, :manual) end)
        {:noreply, put_flash(socket, :info, "Running “#{cron.name}” now…")}
    end
  end

  def handle_event("cron_toggle", %{"id" => id}, socket) do
    case Config.get_cron(id) do
      nil ->
        {:noreply, socket}

      cron ->
        Config.put_cron(%{cron | enabled: !cron.enabled})
        {:noreply, assign(socket, crons: Config.crons())}
    end
  end

  def handle_event("cron_remove", %{"id" => id}, socket) do
    Config.delete_cron(id)
    Cortex.Cron.Log.delete(id)
    {:noreply, assign(socket, crons: Config.crons())}
  end

  def handle_event("cron_create", params, socket) do
    %{"name" => name, "prompt" => prompt, "schedule" => schedule} = params

    case Cortex.Cron.parse(schedule) do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid schedule: #{msg}")}

      {:ok, _} ->
        cron = %Cortex.Config.Cron{
          id: new_cron_id(name),
          name: name,
          agent: blank(params["agent"]) || Config.default_agent_name(),
          prompt: prompt,
          schedule: schedule,
          timezone: blank(params["timezone"]) || Config.default_timezone(),
          model: blank(params["model"]),
          deliver: blank(params["deliver"]) || "none",
          enabled: true
        }

        Config.put_cron(cron)
        {:noreply, socket |> assign(crons: Config.crons()) |> put_flash(:info, "Task created.")}
    end
  end

  def handle_event("pick_learn_agent", %{"agent" => name}, socket) do
    {:noreply, assign(socket, learn_agent: name, learn_nodes: Cortex.Learning.timeline(name))}
  end

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
    socket = assign(socket, sessions: list_sessions())

    socket =
      case socket.assigns.view do
        :learn ->
          assign(socket, learn_nodes: Cortex.Learning.timeline(socket.assigns.learn_agent))

        :cron ->
          assign(socket, crons: Config.crons())

        :bots ->
          assign(socket, bots: Config.telegram_bots())

        _ ->
          socket
      end

    {:noreply, socket}
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
