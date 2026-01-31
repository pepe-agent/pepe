defmodule CortexWeb.DashboardLive do
  @moduledoc """
  The web dashboard: a live list of sessions on the left, a streaming chat panel on
  the right. Pick a session to read its history and talk to its agent; replies stream
  in via PubSub (the run broadcasts its lifecycle events to `"session:<key>"`).

  Risky tools are authorized inline: when an agent (that hasn't pre-approved the tool)
  tries one, the run blocks and the panel shows an allow/deny prompt — the web
  equivalent of the Telegram inline buttons. The owner's omnipotent agent
  (`auto_approve: ["*"]`) never prompts.
  """
  use CortexWeb, :live_view
  use Gettext, backend: Cortex.Gettext

  alias Cortex.Agent.Session
  alias Cortex.Agent.SessionPersistence
  alias Cortex.Agent.SessionSupervisor
  alias Cortex.Config
  alias Cortex.Permissions.Prompt

  # In-chat slash commands (also shown in the "/" menu).
  defp slash_commands do
    [
      {"/new", gettext("Start a fresh conversation")},
      {"/stop", gettext("Stop the current run")},
      {"/compact", gettext("Summarize history to free up context")}
    ]
  end

  @impl true
  def mount(_params, _session, socket) do
    Config.put_locale()
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
       bots: Config.telegram_bots(),
       pending_perm: nil,
       agents: Config.agents(),
       edit_agent: nil,
       models: Config.models(),
       edit_model: nil,
       default_agent: Config.default_agent_name(),
       default_model: Config.default_model_name(),
       mcp: Config.mcp_servers(),
       mcp_tools: %{},
       edit_mcp: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-900 text-zinc-100">
      <aside class="flex w-72 flex-col border-r border-zinc-800">
        <div class="border-b border-zinc-800 px-4 py-3">
          <div class="mb-3 flex items-center gap-2">
            <span class="text-xl">🧠</span>
            <span class="font-semibold">Cortex</span>
          </div>
          <nav class="flex flex-wrap gap-1 text-xs">
            <.tab view={@view} to="chat" label={gettext("Chat")} />
            <.tab view={@view} to="learn" label={gettext("Learn")} />
            <.tab view={@view} to="cron" label={gettext("Cron")} />
            <.tab view={@view} to="bots" label={gettext("Bots")} />
            <.tab view={@view} to="agents" label={gettext("Agents")} />
            <.tab view={@view} to="models" label={gettext("Models")} />
            <.tab view={@view} to="mcp" label={gettext("MCP")} />
          </nav>
        </div>
        <button
          phx-click="new_chat"
          class="m-3 rounded bg-blue-600 px-3 py-2 text-sm font-medium hover:bg-blue-500"
        >
          {gettext("+ New chat")}
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
                  {s.agent || "—"} · {s.model || "—"} · {gettext("%{count} turns", count: s.turns)}
                </div>
              </button>
              <button
                phx-click="delete"
                phx-value-key={s.key}
                data-confirm={gettext("Delete session %{key}?", key: s.key)}
                title={gettext("Delete session")}
                class="px-3 py-2 text-zinc-600 opacity-0 hover:text-red-400 group-hover:opacity-100"
              >
                ✕
              </button>
            </div>
          </div>
          <p :if={@sessions == []} class="px-4 py-6 text-sm text-zinc-500">
            {gettext("No sessions yet — start one.")}
          </p>
        </div>
      </aside>

      <main class="flex flex-1 flex-col">
        <div :if={@view == :learn} class="flex h-full flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">✦ TimeLearn</div>
              <div class="text-xs text-zinc-400">{gettext("what the agent has learned, newest first")}</div>
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
            <p :if={@learn_nodes == []} class="text-sm text-zinc-500">{gettext("Nothing learned yet.")}</p>
          </div>
        </div>

        <div :if={@view == :cron} class="mx-auto flex h-full w-full max-w-3xl flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🕒 {gettext("Scheduled tasks")}</div>
              <div class="text-xs text-zinc-400">{gettext("recurring agent jobs · fire while the server runs")}</div>
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
                    {(c.enabled && gettext("enabled")) || gettext("disabled")}
                  </span>
                </div>
                <div class="flex shrink-0 gap-1 text-xs">
                  <button phx-click="cron_run" phx-value-id={c.id} class="rounded bg-blue-600 px-2 py-1 hover:bg-blue-500">
                    {gettext("Run now")}
                  </button>
                  <button phx-click="cron_toggle" phx-value-id={c.id} class="rounded bg-zinc-700 px-2 py-1 hover:bg-zinc-600">
                    {(c.enabled && gettext("Disable")) || gettext("Enable")}
                  </button>
                  <button
                    phx-click="cron_remove"
                    phx-value-id={c.id}
                    data-confirm={gettext("Remove scheduled task %{name}?", name: c.name)}
                    class="rounded bg-zinc-700 px-2 py-1 text-red-300 hover:bg-zinc-600"
                  >
                    ✕
                  </button>
                </div>
              </div>
              <div class="mt-1 text-xs text-zinc-400">
                <code>{c.schedule}</code> · {c.timezone} · {gettext("next")} {cron_next(c)}
              </div>
              <div class="text-xs text-zinc-500">
                {c.agent}{model_suffix(c.model)} · → {deliver_label(c.deliver)}
              </div>
              <details class="mt-1">
                <summary class="cursor-pointer text-xs text-zinc-500">{gettext("prompt & last runs")}</summary>
                <pre class="mt-1 whitespace-pre-wrap rounded bg-zinc-900 p-2 text-xs text-zinc-300">{c.prompt}</pre>
                <div :for={e <- cron_history(c.id)} class="mt-1 text-xs text-zinc-400">
                  {(e["ok"] && "✅") || "⚠️"} {learn_date(e["at"])} · {e["source"]}
                  <span class="text-zinc-500">— {String.slice(to_string(e["output"]), 0, 120)}</span>
                </div>
              </details>
            </div>
            <p :if={@crons == []} class="text-sm text-zinc-500">{gettext("No scheduled tasks yet — create one below.")}</p>

            <form phx-submit="cron_create" class="space-y-3 rounded-lg border border-blue-800 p-4">
              <div class="text-sm font-medium">{gettext("+ New scheduled task")}</div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Name")}</label>
                <input name="name" placeholder={gettext("Daily XML check")} required
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("What to do")} <span class="text-zinc-600">{gettext("— runs fresh each time, no chat memory")}</span></label>
                <textarea name="prompt" rows="3" required placeholder={gettext("Check the 06:00 XML load and report anything off.")}
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500"></textarea>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="mb-1 block text-xs text-zinc-400">{gettext("When")} <span class="text-zinc-600">{gettext("(cron)")}</span></label>
                  <select name="schedule" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                    <option value="0 8 * * *">{gettext("Every day at 08:00")}</option>
                    <option value="0 * * * *">{gettext("Every hour")}</option>
                    <option value="*/15 * * * *">{gettext("Every 15 minutes")}</option>
                    <option value="0 9 * * 1">{gettext("Every Monday 09:00")}</option>
                    <option value="0 0 1 * *">{gettext("First of the month")}</option>
                  </select>
                </div>
                <div>
                  <label class="mb-1 block text-xs text-zinc-400">{gettext("Timezone")}</label>
                  <select name="timezone" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                    <option :for={tz <- timezone_options()} value={tz}>{tz}</option>
                  </select>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="mb-1 block text-xs text-zinc-400">{gettext("Agent")}</label>
                  <select name="agent" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                    <option :for={a <- agent_names()} value={a}>{a}</option>
                  </select>
                </div>
                <div>
                  <label class="mb-1 block text-xs text-zinc-400">{gettext("Model")}</label>
                  <select name="model" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                    <option value="">{gettext("agent's default")}</option>
                    <option :for={m <- model_names()} value={m}>{m}</option>
                  </select>
                </div>
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Report the result to")}</label>
                <select name="deliver" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                  <option value="none">{gettext("Nowhere (just keep the run history)")}</option>
                  <option value="log">{gettext("The app log")}</option>
                  <option :for={t <- deliver_targets(@sessions)} value={t}>{deliver_label(t)}</option>
                </select>
                <input :if={deliver_targets(@sessions) == []} name="deliver_chat"
                  placeholder={gettext("No Telegram chats yet — paste a chat id (find it with /whoami)")}
                  class="mt-2 w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
              </div>

              <button type="submit" class="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500">
                {gettext("Create task")}
              </button>
            </form>
          </div>
        </div>

        <div :if={@view == :bots} class="mx-auto flex h-full w-full max-w-3xl flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🤖 {gettext("Telegram bots")}</div>
              <div class="text-xs text-zinc-400">
                {gettext("one poller per bot, each bound to an agent · changes apply live")}
              </div>
            </div>
          </header>
          <div class="flex-1 space-y-4 overflow-y-auto p-4">
            <div :for={b <- @bots} class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <span class="font-medium">{b["name"]}</span>
                  <span class={["ml-2 rounded px-1.5 text-xs", bot_active?(b) && "bg-green-700" || "bg-zinc-700 text-zinc-400"]}>
                    {(bot_active?(b) && gettext("active")) || gettext("inactive")}
                  </span>
                </div>
                <button
                  :if={b["name"] != "default"}
                  phx-click="bot_remove"
                  phx-value-name={b["name"]}
                  data-confirm={gettext("Remove bot %{name}?", name: b["name"])}
                  class="rounded bg-zinc-700 px-2 py-1 text-xs text-red-300 hover:bg-zinc-600"
                >
                  ✕
                </button>
              </div>
              <div class="mt-1 text-xs text-zinc-400">{gettext("agent:")} {b["agent"] || gettext("(default)")}</div>
              <div class="text-xs text-zinc-500">{gettext("token:")} {token_hint(b["bot_token"])}</div>
            </div>
            <p :if={@bots == []} class="text-sm text-zinc-500">
              {gettext("No bots yet. The default bot is set via")} <code>mix cortex gateway telegram setup</code>.
            </p>

            <form phx-submit="bot_add" class="space-y-3 rounded-lg border border-blue-800 p-4">
              <div class="text-sm font-medium">{gettext("+ Add a bot")}</div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Name")}</label>
                <input name="name" placeholder={gettext("sales")} required
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
              </div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Bot token")} <span class="text-zinc-600">{gettext("— from @BotFather")}</span></label>
                <input name="token" placeholder="123456:ABC…  or  ${SALES_BOT_TOKEN}" required
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                <p class="mt-1 text-xs text-zinc-500">{gettext("Tip: use an env-var reference to keep the token out of the config file.")}</p>
              </div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("This bot talks to")}</label>
                <select name="agent" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                  <option value="">{gettext("the default agent")}</option>
                  <option :for={a <- agent_names()} value={a}>{a}</option>
                </select>
              </div>
              <button type="submit" class="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500">
                {gettext("Add bot")}
              </button>
            </form>
          </div>
        </div>

        <div :if={@view == :agents} class="mx-auto flex h-full w-full max-w-3xl flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🧩 {gettext("Agents")}</div>
              <div class="text-xs text-zinc-400">{gettext("persona, model, tools, routes & admin scope")}</div>
            </div>
            <button phx-click="agent_new" class="rounded bg-blue-600 px-3 py-1 text-sm hover:bg-blue-500">
              {gettext("+ New")}
            </button>
          </header>
          <div class="flex-1 space-y-3 overflow-y-auto p-4">
            <div :for={a <- @agents} class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <span class="font-medium">{a.name}</span>
                  <span :if={a.name == @default_agent} class="ml-2 rounded bg-green-700 px-1.5 text-xs">{gettext("default")}</span>
                </div>
                <div class="flex shrink-0 gap-1 text-xs">
                  <button phx-click="agent_edit" phx-value-name={a.name} class="rounded bg-zinc-700 px-2 py-1 hover:bg-zinc-600">{gettext("Edit")}</button>
                  <button :if={a.name != @default_agent} phx-click="agent_default" phx-value-name={a.name} class="rounded bg-zinc-700 px-2 py-1 hover:bg-zinc-600">{gettext("Set default")}</button>
                  <button phx-click="agent_delete" phx-value-name={a.name} data-confirm={gettext("Delete agent %{name}?", name: a.name)} class="rounded bg-zinc-700 px-2 py-1 text-red-300 hover:bg-zinc-600">✕</button>
                </div>
              </div>
              <div class="mt-1 text-xs text-zinc-400">{gettext("model:")} {a.model || gettext("(default)")} · {gettext("%{count} tools", count: length(a.tools))}</div>
              <div :if={a.can_message != []} class="text-xs text-zinc-500">→ {gettext("messages:")} {Enum.join(a.can_message, ", ")}</div>
              <div :if={a.can_manage} class="text-xs text-zinc-500">⚙ {gettext("manages:")} {manages_text(a.can_manage)}</div>
            </div>

            <form :if={@edit_agent} phx-submit="agent_save" class="space-y-3 rounded-lg border border-blue-800 p-4">
              <div class="text-sm font-medium">{if @edit_agent.new?, do: gettext("+ New agent"), else: gettext("Edit %{name}", name: @edit_agent.name)}</div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Name")}</label>
                <input name="name" value={@edit_agent.name} placeholder={gettext("assistant")} required readonly={!@edit_agent.new?}
                  class={["w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500", !@edit_agent.new? && "opacity-60"]} />
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Persona (system prompt)")}</label>
                <textarea name="system_prompt" rows="3" placeholder={gettext("You are …")}
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">{@edit_agent.system_prompt}</textarea>
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Model")}</label>
                <select name="model" class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                  <option value="">{gettext("(use default model)")}</option>
                  <option :for={m <- model_names()} value={m} selected={m == @edit_agent.model}>{m}</option>
                </select>
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Tools")} <span class="text-zinc-600">{gettext("— what this agent can do")}</span></label>
                <div class="grid grid-cols-2 gap-1 rounded bg-zinc-900/60 p-2">
                  <label :for={t <- Cortex.Tools.names()} class="flex items-center gap-1.5 text-xs text-zinc-300">
                    <input type="checkbox" name="tools[]" value={t} checked={t in @edit_agent.tools} /> {t}
                  </label>
                </div>
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Can message — agents it may talk to")}</label>
                <input name="can_message" value={Enum.join(@edit_agent.can_message, ",")} placeholder={gettext("e.g. helper, researcher")}
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                <p class="mt-1 text-xs text-zinc-500">{gettext("Comma-separated agent names. Blank = talks to no one.")}</p>
              </div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Admin scope — which agents it can manage & train")}</label>
                <input name="can_manage" value={manage_field(@edit_agent.can_manage)} placeholder={gettext("blank")}
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                <p class="mt-1 text-xs text-zinc-500">
                  <span class="text-zinc-400">{gettext("blank")}</span> = {gettext("itself only")} ·
                  <code class="text-zinc-300">none</code> = {gettext("nobody")} ·
                  <code class="text-zinc-300">*</code> = {gettext("all agents")} ·
                  <code class="text-zinc-300">a,b</code> = {gettext("only those")}
                </p>
              </div>

              <div class="flex gap-2 pt-1">
                <button type="submit" class="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500">{gettext("Save")}</button>
                <button type="button" phx-click="agent_cancel" class="rounded bg-zinc-700 px-4 py-1.5 text-sm hover:bg-zinc-600">{gettext("Cancel")}</button>
              </div>
            </form>
          </div>
        </div>

        <div :if={@view == :models} class="mx-auto flex h-full w-full max-w-3xl flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🔌 {gettext("Model connections")}</div>
              <div class="text-xs text-zinc-400">{gettext("OpenAI-compatible endpoints")}</div>
            </div>
            <button phx-click="model_new" class="rounded bg-blue-600 px-3 py-1 text-sm hover:bg-blue-500">{gettext("+ New")}</button>
          </header>
          <div class="flex-1 space-y-3 overflow-y-auto p-4">
            <div :for={m <- @models} class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <div class="min-w-0">
                  <span class="font-medium">{m.name}</span>
                  <span :if={m.name == @default_model} class="ml-2 rounded bg-green-700 px-1.5 text-xs">{gettext("default")}</span>
                </div>
                <div class="flex shrink-0 gap-1 text-xs">
                  <button :if={m.name != @default_model} phx-click="model_default" phx-value-name={m.name} class="rounded bg-zinc-700 px-2 py-1 hover:bg-zinc-600">{gettext("Set default")}</button>
                  <button phx-click="model_delete" phx-value-name={m.name} data-confirm={gettext("Delete model %{name}?", name: m.name)} class="rounded bg-zinc-700 px-2 py-1 text-red-300 hover:bg-zinc-600">✕</button>
                </div>
              </div>
              <div class="mt-1 text-xs text-zinc-400">{m.model} · {m.base_url}</div>
            </div>

            <form :if={@edit_model} phx-submit="model_save" class="space-y-3 rounded-lg border border-blue-800 p-4">
              <div class="text-sm font-medium">{gettext("+ New model connection")}</div>

              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Provider")}</label>
                <select name="provider" phx-change="model_pick_provider"
                  class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                  <option value="">{gettext("Choose a provider…")}</option>
                  <option :for={{k, label} <- provider_options()} value={k} selected={k == @edit_model.provider}>{label}</option>
                </select>
              </div>

              <div :if={@edit_model.provider}>
                <div class="space-y-3">
                  <div>
                    <label class="mb-1 block text-xs text-zinc-400">{gettext("Name")} <span class="text-zinc-600">{gettext("(this connection)")}</span></label>
                    <input name="name" value={@edit_model.provider} required
                      class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                  </div>

                  <%!-- base_url: auto-filled for known providers (hidden), typed only for "custom" --%>
                  <input :if={@edit_model.base_url} type="hidden" name="base_url" value={@edit_model.base_url} />
                  <div :if={!@edit_model.base_url}>
                    <label class="mb-1 block text-xs text-zinc-400">{gettext("Base URL")}</label>
                    <input name="base_url" placeholder="https://…/v1" required
                      class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                  </div>

                  <div>
                    <label class="mb-1 block text-xs text-zinc-400">{gettext("Model")}</label>
                    <div :if={@edit_model.models == :loading} class="text-xs text-zinc-500">{gettext("loading models…")}</div>
                    <select :if={is_list(@edit_model.models) and @edit_model.models != []} name="model"
                      class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500">
                      <option :for={id <- @edit_model.models} value={id}>{id}</option>
                    </select>
                    <input :if={@edit_model.models == []} name="model" placeholder={gettext("model id (e.g. gpt-5)")} required
                      class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                  </div>

                  <div :if={@edit_model.env}>
                    <label class="mb-1 block text-xs text-zinc-400">{gettext("API key")}</label>
                    <input name="api_key" value={@edit_model.api_key} phx-blur="model_key"
                      class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                    <p class="mt-1 text-xs text-zinc-500">
                      {gettext("Defaults to the %{env} env var (%{status}). Paste a key here to load its models now.",
                        env: @edit_model.env,
                        status: key_status(@edit_model.env)
                      )}
                    </p>
                  </div>
                </div>
              </div>

              <div class="flex gap-2 pt-1">
                <button type="submit" class="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500">{gettext("Save")}</button>
                <button type="button" phx-click="model_cancel" class="rounded bg-zinc-700 px-4 py-1.5 text-sm hover:bg-zinc-600">{gettext("Cancel")}</button>
              </div>
            </form>
          </div>
        </div>

        <div :if={@view == :mcp} class="mx-auto flex h-full w-full max-w-3xl flex-col">
          <header class="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
            <div>
              <div class="font-medium">🧰 {gettext("MCP servers")}</div>
              <div class="text-xs text-zinc-400">{gettext("external tool servers (Sentry, GitHub, …) · tokens as ${ENV_VAR}")}</div>
            </div>
            <button phx-click="mcp_new" class="rounded bg-blue-600 px-3 py-1 text-sm hover:bg-blue-500">{gettext("+ New")}</button>
          </header>
          <div class="flex-1 space-y-3 overflow-y-auto p-4">
            <div :for={{name, cfg} <- @mcp} class="rounded-lg border border-zinc-800 bg-zinc-800/40 p-3">
              <div class="flex items-center justify-between gap-2">
                <span class="font-medium">{name}</span>
                <div class="flex shrink-0 gap-1 text-xs">
                  <button phx-click="mcp_validate" phx-value-name={name} class="rounded bg-blue-600 px-2 py-1 hover:bg-blue-500">{gettext("Validate (list tools)")}</button>
                  <button phx-click="mcp_remove" phx-value-name={name} data-confirm={gettext("Remove MCP server %{name}?", name: name)} class="rounded bg-zinc-700 px-2 py-1 text-red-300 hover:bg-zinc-600">✕</button>
                </div>
              </div>
              <div class="mt-1 text-xs text-zinc-400"><code>{cfg["command"]} {Enum.join(cfg["args"] || [], " ")}</code></div>
              <div :if={@mcp_tools[name] == :loading} class="mt-1 text-xs text-zinc-500">{gettext("connecting…")}</div>
              <div :if={is_list(@mcp_tools[name])} class="mt-2 space-y-1">
                <div :for={t <- @mcp_tools[name]} class="text-xs text-zinc-400">
                  <code class="text-zinc-300">mcp__{name}__{t["name"]}</code>
                  <span class="text-zinc-500">— {String.slice(to_string(t["description"]), 0, 90)}</span>
                </div>
                <p class="text-xs text-zinc-500">{gettext("Grant an agent only the read tools (Agents tab → Tools) to keep it read-only.")}</p>
              </div>
              <div :if={match?({:error, _}, @mcp_tools[name])} class="mt-1 text-xs text-red-400">
                {gettext("couldn't connect — check the command and the env var token")}
              </div>
            </div>
            <p :if={@mcp == %{}} class="text-sm text-zinc-500">{gettext("No MCP servers yet — add one below.")}</p>

            <form :if={@edit_mcp} phx-submit="mcp_save" class="space-y-3 rounded-lg border border-blue-800 p-4">
              <div class="text-sm font-medium">{gettext("+ New MCP server")}</div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Name")}</label>
                <input name="name" placeholder="sentry" required class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
              </div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Command")}</label>
                <input name="command" value="npx" required class="w-full rounded bg-zinc-800 px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-blue-500" />
              </div>
              <div>
                <label class="mb-1 block text-xs text-zinc-400">{gettext("Arguments")}</label>
                <input name="args" placeholder={"-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"} required class="w-full rounded bg-zinc-800 px-2 py-1.5 font-mono text-sm outline-none focus:ring-1 focus:ring-blue-500" />
                <p class="mt-1 text-xs text-zinc-500">{gettext("Put the token as ${ENV_VAR} — the secret stays out of the config file.")}</p>
              </div>
              <div class="flex gap-2 pt-1">
                <button type="submit" class="rounded bg-blue-600 px-4 py-1.5 text-sm font-medium hover:bg-blue-500">{gettext("Save")}</button>
                <button type="button" phx-click="mcp_cancel" class="rounded bg-zinc-700 px-4 py-1.5 text-sm hover:bg-zinc-600">{gettext("Cancel")}</button>
              </div>
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
                {gettext("New")}
              </button>
              <button
                phx-click="stop"
                disabled={!@running}
                class="rounded bg-zinc-700 px-3 py-1 text-xs hover:bg-zinc-600 disabled:opacity-40"
              >
                {gettext("Stop")}
              </button>
            </div>
          </header>

          <div class="flex-1 space-y-3 overflow-y-auto p-4">
            <div :if={@messages == [] and not @running} class="flex h-full items-center justify-center text-sm text-zinc-600">
              {gettext("Fresh conversation — send a message to start.")}
            </div>
            <.bubble :for={m <- @messages} role={m.role} content={m.content} />
            <.bubble :if={@running and @streaming != ""} role="assistant" content={@streaming} />
            <div :if={@running and @streaming == "" and !@pending_perm} class="text-sm text-zinc-500">…</div>

            <div :if={@pending_perm} class="max-w-2xl rounded-lg border border-amber-600/60 bg-amber-950/30 p-3">
              <div class="mb-2 text-sm">
                🔐 {gettext("Allow me to run the")} <code class="text-amber-300">{@pending_perm.tool}</code> {gettext("tool?")}
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={d <- Prompt.options()}
                  phx-click="perm"
                  phx-value-id={@pending_perm.id}
                  phx-value-decision={Prompt.token(d)}
                  class="rounded bg-zinc-700 px-2 py-1 text-xs hover:bg-zinc-600"
                >
                  {Prompt.label(d)}
                </button>
              </div>
            </div>
          </div>

          <div class="relative border-t border-zinc-800 p-3">
            <div
              :if={slash_matches(@input) != []}
              class="absolute bottom-full left-3 mb-2 w-72 overflow-hidden rounded-lg border border-zinc-700 bg-zinc-900 shadow-xl"
            >
              <button
                :for={{cmd, desc} <- slash_matches(@input)}
                type="button"
                phx-click="run_slash"
                phx-value-cmd={cmd}
                class="flex w-full items-baseline gap-2 px-3 py-2 text-left hover:bg-zinc-800"
              >
                <span class="font-mono text-sm text-blue-400">{cmd}</span>
                <span class="text-xs text-zinc-500">{desc}</span>
              </button>
            </div>

            <form phx-submit="send" phx-change="type" class="flex gap-2">
              <input
                name="text"
                value={@input}
                autocomplete="off"
                placeholder={gettext("Message…  (type / for commands)")}
                class="flex-1 rounded bg-zinc-800 px-3 py-2 outline-none placeholder:text-zinc-500 focus:ring-1 focus:ring-blue-500"
              />
              <button type="submit" class="rounded bg-blue-600 px-4 py-2 font-medium hover:bg-blue-500">
                {gettext("Send")}
              </button>
            </form>
          </div>
        </div>

        <div
          :if={@view == :chat and !@selected}
          class="flex flex-1 items-center justify-center text-zinc-500"
        >
          {gettext("Select or start a session.")}
        </div>
      </main>
    </div>
    """
  end

  attr :view, :atom, required: true
  attr :to, :string, required: true
  attr :label, :string, required: true

  defp tab(assigns) do
    ~H"""
    <button
      phx-click="view"
      phx-value-to={@to}
      class={[
        "rounded px-3 py-1 transition",
        (Atom.to_string(@view) == @to && "bg-blue-600 text-white") ||
          "bg-zinc-800 text-zinc-300 hover:bg-zinc-700"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :role, :string, required: true
  attr :content, :string, required: true

  defp bubble(assigns) do
    ~H"""
    <div class={["max-w-2xl whitespace-pre-wrap rounded-lg px-3 py-2 text-sm leading-relaxed", bubble_class(@role)]}>
      <span :if={@role == "tool_call"} class="text-amber-400">⚙ {@content}</span>
      <span :if={@role != "tool_call"}>{Phoenix.HTML.raw(format_md(@content))}</span>
    </div>
    """
  end

  # Minimal, safe markdown for chat: escape everything, then re-introduce **bold**
  # and `inline code`. Newlines/lists render fine via `whitespace-pre-wrap`.
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

  defp deliver_label("none"), do: gettext("not sent")
  defp deliver_label("telegram:" <> id), do: "Telegram #{id}"
  defp deliver_label(other), do: other

  # A manually-typed Telegram chat id wins over the dropdown; else use the select.
  defp deliver_from(params) do
    case blank(params["deliver_chat"]) do
      nil ->
        blank(params["deliver"]) || "none"

      "telegram:" <> _ = full ->
        full

      chat ->
        "telegram:" <> chat
    end
  end

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

  # Execute a slash command against the selected session.
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

        socket |> assign(input: "") |> put_flash(:info, gettext("Compacting history…"))

      _ ->
        put_flash(socket, :error, gettext("Unknown command %{cmd}", cmd: cmd))
    end
  end

  defp slash?(text), do: String.starts_with?(text, "/")
  defp slash_name(text), do: text |> String.split(~r/\s+/, parts: 2) |> List.first()

  defp slash_matches(input) do
    if slash?(input) do
      Enum.filter(slash_commands(), fn {cmd, _} -> String.starts_with?(cmd, input) end)
    else
      []
    end
  end

  # can_message-style list: comma text → list ("" → []).
  defp parse_list(nil), do: []

  defp parse_list(str),
    do: str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # can_manage: "" → nil (self), "none" → [], "*" → ["*"], "a,b" → [a, b].
  defp parse_manage(v) do
    case blank(v) do
      nil -> nil
      "none" -> []
      "*" -> ["*"]
      str -> parse_list(str)
    end
  end

  # Display of can_manage in the list (guarded so nil isn't shown).
  defp manages_text([]), do: gettext("nobody")
  defp manages_text(["*"]), do: gettext("all agents")
  defp manages_text(list) when is_list(list), do: Enum.join(list, ", ")
  defp manages_text(_), do: gettext("self")

  # can_manage as a form field value.
  defp manage_field(nil), do: ""
  defp manage_field([]), do: "none"
  defp manage_field(["*"]), do: "*"
  defp manage_field(list) when is_list(list), do: Enum.join(list, ",")

  defp bot_active?(bot), do: Cortex.Gateways.Telegram.bot_active?(bot)

  # Fetch a provider's model ids off-process (the `/models` call needs auth + can be
  # slow), and send them back to the LiveView so it can turn the model field into a
  # dropdown. `resolved_key` is the actual key (env var value, or what the user typed).
  defp spawn_model_fetch(provider, base, resolved_key) do
    parent = self()

    spawn(fn ->
      ids =
        with true <- is_binary(base),
             probe = %Cortex.Config.Model{
               name: "probe",
               base_url: base,
               api_key: resolved_key,
               model: "",
               api: "openai"
             },
             {:ok, list} <- Cortex.LLM.list_models(probe) do
          list
        else
          _ -> []
        end

      send(parent, {:models_loaded, provider, ids})
    end)
  end

  defp provider_options, do: Enum.map(Cortex.Providers.all(), &{&1.key, &1.label})

  # Common IANA zones for the cron form, with the configured default first.
  @common_timezones ~w(
    America/Sao_Paulo America/New_York America/Chicago America/Los_Angeles
    America/Mexico_City America/Argentina/Buenos_Aires America/Bogota
    Europe/London Europe/Lisbon Europe/Madrid Europe/Berlin Europe/Paris
    Africa/Johannesburg Asia/Dubai Asia/Kolkata Asia/Shanghai Asia/Tokyo
    Australia/Sydney Etc/UTC
  )

  defp timezone_options do
    default = Config.default_timezone()
    [default | @common_timezones] |> Enum.uniq()
  end

  defp key_status(env) do
    if System.get_env(env),
      do: gettext("✓ it's set."),
      else: gettext("⚠ not set yet — export it before use.")
  end

  defp reject_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  # Apply bot changes to the running pollers (we're inside the serve process).
  defp reload_gateways do
    Cortex.Gateways.Supervisor.reload_telegram()
  rescue
    _ -> :ok
  end

  defp token_hint(nil), do: gettext("(none)")
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

  def handle_event("view", %{"to" => "agents"}, socket) do
    {:noreply, assign(socket, view: :agents, agents: Config.agents(), edit_agent: nil)}
  end

  def handle_event("view", %{"to" => "models"}, socket) do
    {:noreply, assign(socket, view: :models, models: Config.models(), edit_model: nil)}
  end

  def handle_event("view", %{"to" => "mcp"}, socket) do
    {:noreply, assign(socket, view: :mcp, mcp: Config.mcp_servers(), edit_mcp: nil)}
  end

  def handle_event("mcp_new", _p, socket), do: {:noreply, assign(socket, edit_mcp: %{})}
  def handle_event("mcp_cancel", _p, socket), do: {:noreply, assign(socket, edit_mcp: nil)}

  def handle_event("mcp_save", %{"name" => name, "command" => command, "args" => args}, socket) do
    name = String.trim(name)

    if name == "" or String.trim(command) == "" do
      {:noreply, put_flash(socket, :error, gettext("Name and command are required."))}
    else
      Config.put_mcp_server(name, %{
        "command" => String.trim(command),
        "args" => String.split(args, " ", trim: true),
        "env" => %{}
      })

      {:noreply,
       socket
       |> assign(mcp: Config.mcp_servers(), edit_mcp: nil)
       |> put_flash(:info, gettext("MCP server %{name} saved — validate it.", name: name))}
    end
  end

  def handle_event("mcp_remove", %{"name" => name}, socket) do
    Config.delete_mcp_server(name)
    {:noreply, assign(socket, mcp: Config.mcp_servers())}
  end

  def handle_event("mcp_validate", %{"name" => name}, socket) do
    parent = self()

    Task.start(fn ->
      send(parent, {:mcp_validated, name, Cortex.MCP.tools(name)})
    end)

    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, :loading))}
  end

  def handle_event("view", %{"to" => _chat}, socket), do: {:noreply, assign(socket, view: :chat)}

  ###
  ### agents
  ###

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
    name = String.trim(params["name"] || "")

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

  ###
  ### models
  ###

  def handle_event("model_new", _p, socket) do
    {:noreply,
     assign(socket,
       edit_model: %{provider: nil, base_url: nil, env: nil, api_key: nil, models: []}
     )}
  end

  def handle_event("model_cancel", _p, socket), do: {:noreply, assign(socket, edit_model: nil)}

  def handle_event("model_pick_provider", %{"provider" => ""}, socket) do
    {:noreply,
     assign(socket,
       edit_model: %{provider: nil, base_url: nil, env: nil, api_key: nil, models: []}
     )}
  end

  def handle_event("model_pick_provider", %{"provider" => key}, socket) do
    p = Cortex.Providers.get(key)
    env = p && p[:env]
    base = p && p[:base_url]

    state = %{
      provider: key,
      base_url: base,
      env: env,
      api_key: if(env, do: "${#{env}}", else: nil),
      # Fetched live off-process so the LiveView never blocks on the HTTP call.
      models: :loading
    }

    spawn_model_fetch(key, base, env && System.get_env(env))
    {:noreply, assign(socket, edit_model: state)}
  end

  # Re-fetch the model list using the key the user typed (resolving `${ENV}` refs),
  # so the dropdown fills even when the env var isn't set yet.
  def handle_event("model_key", %{"value" => raw}, socket) do
    case socket.assigns.edit_model do
      %{provider: p, base_url: base} = m when not is_nil(p) ->
        spawn_model_fetch(p, base, Cortex.Config.interpolate(raw))
        {:noreply, assign(socket, edit_model: %{m | models: :loading})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("model_save", params, socket) do
    name = String.trim(params["name"] || "")

    cond do
      name == "" or blank(params["base_url"]) == nil or blank(params["model"]) == nil ->
        {:noreply,
         put_flash(socket, :error, gettext("Name, base URL and model id are required."))}

      true ->
        Config.put_model(%Cortex.Config.Model{
          name: name,
          base_url: params["base_url"],
          api_key: blank(params["api_key"]),
          model: params["model"]
        })

        {:noreply,
         socket
         |> assign(
           models: Config.models(),
           edit_model: nil,
           default_model: Config.default_model_name()
         )
         |> put_flash(:info, gettext("Model %{name} saved.", name: name))}
    end
  end

  def handle_event("model_delete", %{"name" => name}, socket) do
    Config.delete_model(name)

    {:noreply,
     assign(socket, models: Config.models(), default_model: Config.default_model_name())}
  end

  def handle_event("model_default", %{"name" => name}, socket) do
    Config.set_default_model(name)
    {:noreply, assign(socket, default_model: name)}
  end

  def handle_event("bot_add", %{"name" => name, "token" => token} = params, socket) do
    name = String.trim(name)

    cond do
      name in ["", "default"] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a name other than \"default\"."))}

      blank(token) == nil ->
        {:noreply, put_flash(socket, :error, gettext("A bot token is required."))}

      true ->
        map = %{"bot_token" => token, "agent" => blank(params["agent"])}
        Config.put_telegram_bot(name, reject_nil(map))
        reload_gateways()

        {:noreply,
         socket
         |> assign(bots: Config.telegram_bots())
         |> put_flash(:info, gettext("Bot %{name} added.", name: name))}
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
        {:noreply, put_flash(socket, :error, gettext("Task not found."))}

      cron ->
        # Fire off the main-loop path; the run can take a while, so don't block LiveView.
        Task.start(fn -> Cortex.Cron.run(cron, :manual) end)
        {:noreply, put_flash(socket, :info, gettext("Running “%{name}” now…", name: cron.name))}
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
        {:noreply, put_flash(socket, :error, gettext("Invalid schedule: %{msg}", msg: msg))}

      {:ok, _} ->
        cron = %Cortex.Config.Cron{
          id: new_cron_id(name),
          name: name,
          agent: blank(params["agent"]) || Config.default_agent_name(),
          prompt: prompt,
          schedule: schedule,
          timezone: blank(params["timezone"]) || Config.default_timezone(),
          model: blank(params["model"]),
          deliver: deliver_from(params),
          enabled: true
        }

        Config.put_cron(cron)

        {:noreply,
         socket |> assign(crons: Config.crons()) |> put_flash(:info, gettext("Task created."))}
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
      _ -> {:noreply, put_flash(socket, :error, gettext("No default agent configured."))}
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
    if socket.assigns.selected do
      {:noreply, run_slash_command(socket, cmd)}
    else
      {:noreply, socket}
    end
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

  def handle_info({:compacted, key}, socket) do
    if key == socket.assigns.selected do
      {:noreply, assign(socket, messages: history(key))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:mcp_validated, name, result}, socket) do
    value =
      case result do
        {:ok, tools} -> tools
        {:error, reason} -> {:error, reason}
      end

    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, value))}
  end

  def handle_info({:models_loaded, provider, ids}, socket) do
    case socket.assigns.edit_model do
      %{provider: ^provider} = m -> {:noreply, assign(socket, edit_model: %{m | models: ids})}
      _ -> {:noreply, socket}
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

        :agents ->
          assign(socket, agents: Config.agents())

        :models ->
          assign(socket, models: Config.models())

        _ ->
          socket
      end

    {:noreply, socket}
  end

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

    # Ask before a risky tool runs (unless the agent pre-approved it). The callback
    # runs in the run process: it publishes a request the LiveView renders, then
    # blocks until the user clicks a button (or times out → deny).
    authorize = fn name, _args, _ctx ->
      id = System.unique_integer([:positive])
      requester = self()

      Phoenix.PubSub.broadcast(
        Cortex.PubSub,
        topic,
        {:session_event, key, {:permission_request, id, name, requester}}
      )

      receive do
        {:perm_reply, ^id, decision} -> decision
      after
        120_000 -> :deny
      end
    end

    # The session already exists and is bound to its agent, so talk to it directly.
    spawn(fn ->
      Session.chat(key, text, stream: true, on_event: on_event, authorize: authorize)
    end)
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

  defp type_label("telegram"), do: gettext("Telegram")
  defp type_label("web"), do: gettext("Web")
  defp type_label("tui"), do: gettext("Console")
  defp type_label("api"), do: gettext("API")
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
