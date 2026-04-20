defmodule Pepe.Gateways.Telegram do
  @moduledoc """
  Telegram gateway via long polling (`getUpdates`). Each chat maps to a persistent
  Pepe session, so conversations keep context - talk to your agent from Telegram
  while it works.

  **Multi-channel:** you can run several bots at once, each bound to its own agent -
  one bot is agent X, another is agent Y. `Pepe.Gateways.Supervisor` starts one
  instance of this GenServer per configured bot; each keeps the bot map it serves in
  its process dictionary (`@bot_key`), so its token, bound agent, allowlists and
  session-key namespace are all its own. The default (legacy) bot uses the plain
  `telegram:<chat_id>` session key; named bots use `telegram:<name>:<chat_id>`.

  Configuration - the default bot lives under `"telegram"`, additional bots under
  `"telegrams"` (a name->config map), in `~/.pepe/config.json`:

      {
        "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "agent": "assistant" },
        "telegrams": {
          "sales": { "bot_token": "${SALES_BOT_TOKEN}", "agent": "sales-bot" }
        }
      }

  Each bot map accepts:

      {
        "bot_token": "${TELEGRAM_BOT_TOKEN}",
        "enabled": true,               // optional; false disables without deleting
        "allowed_chats": [12345],      // optional chat allowlist; empty = any chat
        "allowed_users": [67890],      // optional user allowlist; empty = any user
        "require_mention": true,       // optional; in groups only reply when @mentioned
        "agent": "assistant"           // the agent this bot talks to
      }

  `require_mention` is bot-wide (every group that bot is in). Any single group can
  waive it for itself with `/mention off` (back on with `/mention on`) - the waiver
  lives on that group's own session, so it never affects other groups the same bot
  serves, and is forgotten on `/new`.
  """
  use GenServer
  use Gettext, backend: Pepe.Gettext

  require Logger

  alias Pepe.Company
  alias Pepe.Config
  alias Pepe.ModelSwitch
  alias Pepe.Permissions.Prompt

  @poll_timeout 30

  # The emoji dropped on the user's own message while the agent works (reaction mode).
  @work_reaction "👀"

  # Pending permission prompts: request_id => the waiting session pid. Lives in a
  # public ETS table so the poll loop (this process) can answer a `receive` that's
  # blocking in a Session process.
  @pending :pepe_tg_pending
  # How long to wait for a button press before denying.
  @perm_timeout 120_000

  # Tool-approval prompts already answered this turn (chat_id => message_id), so
  # they can be deleted once the turn ends - each has already served its purpose
  # (confirming the tap), and leaving it in the transcript afterward is just
  # permission-bookkeeping clutter next to the actual conversation.
  @prompt_log :pepe_tg_prompt_log

  # The built-in slash commands. Descriptions are built at runtime so they're
  # translated in the active locale. Installed skills are appended dynamically by
  # `full_menu/0`, so they show up in Telegram's "/" popup too.
  @spec menu() :: [{String.t(), String.t()}]
  defp menu do
    [
      {"new", gettext("Start a fresh conversation")},
      {"undo", gettext("Undo your last message")},
      {"mention", gettext("In a group, require an @mention or not - /mention on|off")},
      {"compact", gettext("Summarize history to free up context")},
      {"agent", gettext("Switch agent - /agent <name>")},
      {"model", gettext("Show or set the model - /model <name>")},
      {"models", gettext("List configured models")},
      {"tools", gettext("List available runtime tools")},
      {"skill", gettext("List or run a skill - /skill <name>")},
      {"approve", gettext("Manage saved tool permissions - /approve")},
      {"status", gettext("Show session info")},
      {"whoami", gettext("Show your Telegram ids")},
      {"btw", gettext("Ask a side question that isn't saved - /btw <q>")},
      {"learn", gettext("Save what I learned to memory/skills")},
      {"stop", gettext("Stop the current run")},
      {"help", gettext("List commands")}
    ]
  end

  # Built-in commands plus one command per installed skill (so skills are
  # discoverable from the "/" menu too).
  @spec full_menu() :: [{String.t(), String.t()}]
  defp full_menu, do: menu() ++ skill_commands()

  # Each skill as a `{command, description}`. Names are normalized to Telegram's
  # command charset; any that would collide with a built-in are dropped.
  @spec skill_commands() :: [{String.t(), String.t()}]
  defp skill_commands do
    reserved = MapSet.new(Enum.map(menu(), &elem(&1, 0)))

    Pepe.Skills.list()
    |> Enum.map(fn {name, summary} ->
      {command_name(name), command_desc(skill_summary(name) || summary, name)}
    end)
    |> Enum.reject(fn {cmd, _desc} -> cmd == "" or MapSet.member?(reserved, cmd) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # The skill whose command form matches `cmd`, or nil.
  @spec skill_for_command(String.t()) :: String.t() | nil
  defp skill_for_command(cmd) do
    Enum.find_value(Pepe.Skills.list(), fn {name, _summary} ->
      if command_name(name) == cmd, do: name
    end)
  end

  # Telegram commands: lowercase a-z, digits, underscore, ≤32 chars.
  @spec command_name(String.t()) :: String.t()
  defp command_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 32)
  end

  # Telegram descriptions must be 1-256 chars; fall back to a generic line.
  @spec command_desc(String.t(), String.t()) :: String.t()
  defp command_desc(summary, name) do
    case summary |> to_string() |> String.trim() |> String.slice(0, 256) do
      "" -> gettext("Run the %{name} skill", name: name)
      desc -> desc
    end
  end

  ###
  ### lifecycle
  ###

  # Each poller (one per bot) keeps the bot map it serves in its process
  # dictionary, so the many token/agent/allowlist/send helpers can stay single-arg
  # while still reading *their* bot. Cross-process hops re-install it explicitly:
  # spawned Tasks (`respond`/`ingest_media`/`register_commands`), the Session's
  # `authorize` callback, and cron `deliver/2`.
  @bot_key :pepe_tg_bot

  @doc "Is at least one Telegram bot configured and enabled?"
  def enabled?, do: Enum.any?(Config.telegram_bots(), &bot_active?/1)

  @doc "Is this bot map enabled and does it resolve to a usable token?"
  def bot_active?(bot) when is_map(bot),
    do: bot["enabled"] != false and not is_nil(resolve_token(bot))

  def start_link(bot), do: GenServer.start_link(__MODULE__, bot, [])

  defp put_bot(bot), do: Process.put(@bot_key, bot || %{})
  defp bot, do: Process.get(@bot_key) || %{}
  defp bot_name, do: bot()["name"] || "default"

  defp token, do: resolve_token(bot())

  defp resolve_token(bot),
    do: bot |> Map.get("bot_token") |> Pepe.Config.interpolate() |> presence()

  # The agent this bot is bound to (its whole reason for existing), else the global
  # default. This is how "this channel talks only to agent X" works per bot.
  defp agent_default, do: bot()["agent"] || Config.default_agent_name()

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v), do: v

  ###
  ### server
  ###

  @impl true
  def init(bot) do
    put_bot(bot)
    Logger.info("[telegram] gateway starting for bot #{bot_name()}")
    # Fresh start: forget any cached bot username (the token may be a new bot).
    :persistent_term.erase({__MODULE__, :username, bot_name()})
    if :ets.whereis(@pending) == :undefined, do: :ets.new(@pending, [:set, :public, :named_table])
    if :ets.whereis(@prompt_log) == :undefined, do: :ets.new(@prompt_log, [:bag, :public, :named_table])
    b = bot()

    Task.start(fn ->
      put_bot(b)
      register_commands()
    end)

    send(self(), :poll)
    schedule_heartbeat_tick()
    {:ok, %{offset: 0, heartbeat_last: 0}}
  end

  # Scopes Pepe never sets itself. A more-specific scope (e.g. a leftover set by
  # another app that shared this token) overrides our default menu - so we clear
  # them on boot to make sure our default-scope commands always win.
  @owned_scopes ["all_private_chats", "all_group_chats", "all_chat_administrators"]

  # Publish the command list so it shows in Telegram's "/" menu, and clear any
  # stale command sets in the scopes we don't use, so ours are always what shows.
  defp register_commands do
    Config.put_locale()
    commands = Enum.map(full_menu(), fn {name, desc} -> %{command: name, description: desc} end)
    Req.post(api_url(token(), "setMyCommands"), json: %{commands: commands})

    for scope <- @owned_scopes do
      Req.post(api_url(token(), "deleteMyCommands"), json: %{scope: %{type: scope}})
    end
  end

  @impl true
  def handle_info(:poll, state) do
    # Read the token fresh each poll so a token change in the config takes effect
    # live - no restart needed (most config is hot-reloaded this way).
    state =
      case token() && get_updates(token(), state.offset) do
        {:ok, updates} ->
          Enum.each(updates, &handle_update/1)
          %{state | offset: next_offset(updates, state.offset)}

        nil ->
          Process.sleep(2_000)
          state

        {:error, reason} ->
          Logger.warning("[telegram] poll error: #{safe_inspect(reason)}")
          Process.sleep(2_000)
          state
      end

    send(self(), :poll)
    {:noreply, state}
  end

  # Opt-in proactive engine: once a minute, check whether this bot's heartbeat is
  # due (config `"heartbeat_minutes"`, nil = disabled) and, if so, pulse each of its
  # sessions off-process. A quiet pulse (the overwhelmingly common case) never
  # reaches the chat; only a genuine `{:ok, text}` gets delivered.
  @impl true
  def handle_info(:heartbeat_tick, state) do
    b = bot()
    now = System.system_time(:second)

    state = maybe_pulse_heartbeat(state, b, now)

    schedule_heartbeat_tick()
    {:noreply, state}
  end

  defp maybe_pulse_heartbeat(state, b, now) do
    case b["heartbeat_minutes"] do
      minutes when is_integer(minutes) and minutes > 0 ->
        if now - state.heartbeat_last >= minutes * 60 and heartbeat_hour_ok?(b) do
          pulse_sessions(b)
          %{state | heartbeat_last: now}
        else
          state
        end

      _ ->
        state
    end
  end

  defp pulse_sessions(b) do
    for key <- bot_session_keys(b) do
      Task.start(fn ->
        put_bot(b)
        deliver_heartbeat(key)
      end)
    end
  end

  defp schedule_heartbeat_tick, do: Process.send_after(self(), :heartbeat_tick, 60_000)

  defp heartbeat_hour_ok?(bot) do
    tz = bot["timezone"] || Config.default_timezone()

    case DateTime.now(tz) do
      {:ok, dt} -> Pepe.Heartbeat.active_hours?(bot["heartbeat_active_hours"], dt.hour)
      _ -> true
    end
  end

  # Session keys belonging to THIS bot: "telegram:<chat_id>" for the default bot,
  # "telegram:<name>:<chat_id>" for a named one - never another bot's sessions.
  defp bot_session_keys(bot) do
    name = bot["name"] || "default"
    prefix = if name == "default", do: "telegram:", else: "telegram:#{name}:"

    Pepe.Agent.SessionPersistence.all()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&own_key?(&1, name, prefix))
  end

  # A named-bot key looks like "telegram:<name>:<chat_id>" (one more ":" after the
  # prefix); the default bot's own keys never have that extra segment.
  defp own_key?(key, "default", prefix) do
    String.starts_with?(key, prefix) and
      not String.contains?(String.trim_leading(key, prefix), ":")
  end

  defp own_key?(key, _name, prefix), do: String.starts_with?(key, prefix)

  defp deliver_heartbeat(key) do
    Config.put_locale()

    case Pepe.Heartbeat.pulse(key) do
      {:ok, text} ->
        chat_id = key |> String.split(":") |> List.last()
        send_message(chat_id, text)

      _silent_or_deferred_or_error ->
        :ok
    end
  end

  defp next_offset([], offset), do: offset

  defp next_offset(updates, _offset) do
    updates |> Enum.map(& &1["update_id"]) |> Enum.max() |> Kernel.+(1)
  end

  ###
  ### telegram API
  ###

  defp api_url(token, method), do: "https://api.telegram.org/bot#{token}/#{method}"

  @doc """
  Deliver a fired watch's message to a Telegram chat, resolving the bot token from
  config so it works from any process (e.g. the watch scheduler task, which doesn't
  hold a bot in its process dictionary). Returns `:ok`/`{:error, reason}`.
  """
  def deliver_watch(%{"chat_id" => chat_id} = origin, text) do
    bot_name = origin["bot"] || "default"

    case Config.telegram_bot(bot_name) do
      %{"bot_token" => raw} ->
        token = Config.interpolate(raw)
        url = api_url(token, "sendMessage")
        send_watch_message(url, chat_id, text)

      _ ->
        {:error, :unknown_bot}
    end
  end

  def deliver_watch(_origin, _text), do: {:error, :no_chat}

  defp send_watch_message(url, chat_id, text) do
    html = Pepe.Gateways.Telegram.Markdown.to_html(text)

    case Req.post(url, json: %{chat_id: chat_id, text: html, parse_mode: "HTML"}) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        # formatting rejected: fall back to plain text so the alert still lands
        send_watch_plain(url, chat_id, text)
    end
  end

  defp send_watch_plain(url, chat_id, text) do
    case Req.post(url, json: %{chat_id: chat_id, text: text}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:telegram, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The bot token rides in the URL *path* (`/bot<id>:<secret>/method`), so a Req/Mint
  # error that embeds the request URL leaks it verbatim through `inspect/1`. Mask the
  # token before anything derived from an error reaches the logs.
  defp redact(text) when is_binary(text) do
    Regex.replace(~r/bot\d{6,}(:|%3[aA])[A-Za-z0-9_-]{20,}/, text, "bot<redacted>")
  end

  defp safe_inspect(term), do: term |> inspect() |> redact()

  defp get_updates(token, offset) do
    params = [offset: offset, timeout: @poll_timeout]

    case Req.get(api_url(token, "getUpdates"),
           params: params,
           receive_timeout: (@poll_timeout + 10) * 1000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} -> {:ok, result}
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_update(%{"message" => %{"text" => text} = message}) do
    chat = message["chat"] || %{}
    chat_id = chat["id"]
    user_id = get_in(message, ["from", "id"])

    if active?() and allowed?(chat_id, user_id) and addressed?(text, chat["type"], chat_id) do
      b = bot()

      Task.start(fn ->
        put_bot(b)
        respond(chat_id, user_id, message["message_id"], strip_mention(text))
      end)
    end
  end

  # A pressed permission button. Dismiss the spinner, then hand the decision to the
  # session that's waiting on it (allowlist still applies).
  defp handle_update(%{"callback_query" => %{"data" => "perm:" <> _ = data} = cq}) do
    answer_callback(cq["id"])
    chat_id = get_in(cq, ["message", "chat", "id"])
    user_id = get_in(cq, ["from", "id"])

    if active?() and allowed?(chat_id, user_id) do
      deliver_permission(data, cq)
    end
  end

  # A tapped button from the `/models` picker. Runs straight in this bot's own
  # process (like the "perm:" callback above) - fast, no LLM call, no need for a
  # Task. Permission is recomputed fresh from the presser's id every time, never
  # trusted from when the picker was first sent (`learn?/0`'s per-message cache
  # doesn't apply here - button taps don't go through `respond/4`).
  defp handle_update(%{"callback_query" => %{"data" => "model:" <> _ = data} = cq}) do
    answer_callback(cq["id"])
    chat_id = get_in(cq, ["message", "chat", "id"])
    user_id = get_in(cq, ["from", "id"])
    message_id = get_in(cq, ["message", "message_id"])

    if active?() and allowed?(chat_id, user_id) do
      Config.put_locale()
      handle_model_callback(chat_id, message_id, user_id, data)
    end
  end

  # Non-text messages: download the file into the agent's workspace and hand it the
  # path, so it can figure out how to understand it (transcribe, read, ...) with its
  # own tools - installing whatever it needs. We don't hardcode transcription.
  defp handle_update(%{"message" => %{"voice" => %{"file_id" => id}} = m}),
    do: media(m, id, "voice")

  defp handle_update(%{"message" => %{"audio" => %{"file_id" => id}} = m}),
    do: media(m, id, "audio")

  defp handle_update(%{"message" => %{"video_note" => %{"file_id" => id}} = m}),
    do: media(m, id, "voice")

  defp handle_update(%{"message" => %{"document" => %{"file_id" => id}} = m}),
    do: media(m, id, "document")

  defp handle_update(%{"message" => %{"photo" => [_ | _] = sizes} = m}),
    do: media(m, List.last(sizes)["file_id"], "photo")

  defp handle_update(_), do: :ok

  defp media(message, file_id, kind) do
    chat = message["chat"] || %{}
    chat_id = chat["id"]
    user_id = get_in(message, ["from", "id"])
    caption = message["caption"] || ""

    if active?() and allowed?(chat_id, user_id) and addressed?(caption, chat["type"], chat_id) do
      b = bot()

      learn = learn_allowed?(user_id)

      Task.start(fn ->
        put_bot(b)
        put_learn(learn)
        ingest_media(chat_id, file_id, kind, caption)
      end)
    end
  end

  defp ingest_media(chat_id, file_id, kind, caption) do
    Config.put_locale()
    send_chat_action(chat_id, "typing")

    case download_file(file_id, kind) do
      {:ok, path} ->
        chat_with_agent(chat_id, nil, media_prompt(kind, path, caption))

      :error ->
        Logger.warning("[telegram] could not download #{kind} #{file_id}")
        send_message(chat_id, friendly_error(:download))
    end
  end

  # Download the Telegram file into the agent's workspace under `media/`, returning
  # the workspace-relative path the agent's tools can use.
  defp download_file(file_id, kind) do
    with {:ok, file_path} <- telegram_file_path(file_id),
         url = "https://api.telegram.org/file/bot#{token()}/#{file_path}",
         {:ok, %{status: 200, body: body}} when is_binary(body) <- Req.get(url) do
      agent = agent_default()
      dir = Path.join(Pepe.Agent.Workspace.dir(agent), "media")
      File.mkdir_p!(dir)
      name = "#{kind}_#{System.unique_integer([:positive])}#{Path.extname(file_path)}"
      File.write!(Path.join(dir, name), body)
      {:ok, "media/#{name}"}
    else
      _ -> :error
    end
  end

  defp telegram_file_path(file_id) do
    case Req.get(api_url(token(), "getFile"), params: [file_id: file_id]) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"file_path" => path}}}} ->
        {:ok, path}

      _ ->
        :error
    end
  end

  # Agent-facing instruction (English; the agent replies in the user's language).
  defp media_prompt("voice", path, caption),
    do:
      "The user sent a voice message, saved in your workspace at `#{path}` (Telegram's OGG/Opus format)." <>
        transcription_hint() <>
        " Once you have the text, respond to what they actually said." <>
        caption_line(caption)

  defp media_prompt("audio", path, caption),
    do:
      "The user sent an audio file, saved at `#{path}`." <>
        transcription_hint() <>
        " Once you have the text, respond to its content." <>
        caption_line(caption)

  defp media_prompt("photo", path, caption),
    do:
      "The user sent a photo, saved at `#{path}`. Look at it and respond to what they want." <>
        caption_line(caption)

  defp media_prompt("document", path, caption),
    do:
      "The user sent a file, saved at `#{path}`. Inspect it and help with whatever they need." <>
        caption_line(caption)

  # A concrete playbook, not just "transcribe it" - the agent has bash, so give it an
  # actual path to a working transcription instead of leaving it to guess. Installing a
  # local tool goes through the normal risky-command permission prompt like any other
  # bash use - nothing audio-specific about that gate.
  defp transcription_hint do
    " To transcribe it, try in order: a speech-to-text tool already on this machine " <>
      "(`whisper-cli`, `whisper`); if none is available, install one yourself " <>
      "(`pip install -q openai-whisper` or `pipx install openai-whisper`, then run " <>
      "`whisper <path> --model tiny --fp16 False` - the first run downloads a small model, " <>
      "that's normal and can take a minute); or, if a configured model connection's provider " <>
      "exposes an OpenAI-compatible `/audio/transcriptions` endpoint (e.g. Groq, or OpenAI with " <>
      "a real API key), call that directly instead of installing anything."
  end

  defp caption_line(""), do: ""
  defp caption_line(caption), do: "\n\nTheir caption: #{caption}"

  defp respond(chat_id, user_id, msg_id, text) do
    Config.put_locale()
    put_learn(learn_allowed?(user_id))

    case parse_command(text) do
      # /whoami is the one command that needs the sender id.
      {:command, "whoami", _args} -> whoami(chat_id, user_id)
      {:command, name, args} -> run_command(chat_id, name, args)
      :chat -> chat_with_agent(chat_id, msg_id, text)
    end
  end

  # "/cmd@botname args" -> {:command, "cmd", "args"}; anything else -> :chat.
  defp parse_command("/" <> rest) do
    {cmd, args} =
      case String.split(rest, ~r/\s+/, parts: 2) do
        [c] -> {c, ""}
        [c, a] -> {c, a}
      end

    cmd = cmd |> String.split("@") |> List.first() |> String.downcase()
    {:command, cmd, String.trim(args)}
  end

  defp parse_command(_), do: :chat

  defp chat_with_agent(chat_id, msg_id, text) do
    agent = agent_default()
    typing = keep_typing(chat_id)
    if progress_mode() == "reaction", do: set_reaction(chat_id, msg_id, @work_reaction)

    try do
      case Pepe.Agent.chat(session_key(chat_id), agent, text,
             authorize: authorizer(chat_id),
             learn: learn?(),
             on_event: activity_callback(chat_id)
           ) do
        {:ok, reply} ->
          send_message(chat_id, reply)

        {:error, :stopped} ->
          # The user issued /stop; that command already acknowledged it.
          :ok

        {:error, :busy} ->
          send_message(
            chat_id,
            gettext("I'm still on the previous message - send /stop to cancel it.")
          )

        {:error, reason} ->
          # Never leak raw internal errors into the chat - log them, reply kindly.
          Logger.warning("[telegram] chat error: #{safe_inspect(reason)}")
          send_message(chat_id, friendly_error(reason))
      end
    after
      stop_typing(typing)
      cleanup_prompts(chat_id)
      if progress_mode() == "reaction", do: set_reaction(chat_id, msg_id, nil)
    end
  end

  # Once a turn ends (however it ends), delete the tool-approval bubbles it left
  # behind - each already served its purpose (confirming the tap), so keeping them
  # around afterward is just permission-bookkeeping clutter, not conversation.
  defp cleanup_prompts(chat_id) do
    @prompt_log
    |> :ets.take(chat_id)
    |> Enum.each(fn {^chat_id, message_id} ->
      Req.post(api_url(token(), "deleteMessage"), json: %{chat_id: chat_id, message_id: message_id})
    end)
  end

  # Map internal errors to a short, user-safe message (no structs/stacktraces).
  defp friendly_error(%Req.TransportError{}),
    do: gettext("I'm having a connection problem right now. Could you try again?")

  defp friendly_error(:download),
    do: gettext("I couldn't download that file. Could you send it again?")

  defp friendly_error(%{reason: :timeout}),
    do: gettext("That took too long. Could you try again, please?")

  defp friendly_error({:http_error, status, _}) when status in [401, 403],
    do: gettext("My credentials need to be refreshed. Please ask the team to reconnect.")

  defp friendly_error({:http_error, _status, _}),
    do: gettext("The model returned an error just now. Could you try again?")

  defp friendly_error(:budget_exceeded),
    do: gettext("This workspace has hit its monthly spending limit. It resumes next month, or an admin can raise the cap.")

  defp friendly_error(:message_limit_exceeded),
    do: gettext("This workspace has hit its monthly message limit. It resumes next month, or an admin can raise the cap.")

  defp friendly_error(_),
    do: gettext("Sorry, something went wrong on my end. Try again in a moment?")

  ###
  ### permissions (native inline-button prompt)
  ###

  # The `authorize` callback Pepe calls before a risky tool runs. It executes in
  # the Session process; we render Telegram's own inline keyboard and block until
  # the poll loop delivers the pressed button (or we time out -> deny).
  defp authorizer(chat_id) do
    # Captured here (in the bot's task) and re-installed when the Session process
    # invokes the callback, so the prompt is sent via *this* bot's token.
    b = bot()

    fn name, args, _ctx ->
      put_bot(b)
      request_authorization(chat_id, name, args)
    end
  end

  defp request_authorization(chat_id, name, args) do
    id = System.unique_integer([:positive])
    :ets.insert(@pending, {id, self()})
    send_permission_prompt(chat_id, id, name, args)

    receive do
      {:perm_reply, ^id, decision} -> decision
    after
      @perm_timeout ->
        :ets.delete(@pending, id)
        :deny
    end
  end

  defp send_permission_prompt(chat_id, id, name, args) do
    Config.put_locale()
    map = decode_args(args)
    text = esc(Prompt.question(name)) <> risk_lines(name, map) <> arg_block(map)

    # One button per shared decision, rendered as Telegram's inline keyboard.
    buttons =
      Enum.map(Prompt.options(), fn decision ->
        [%{text: Prompt.label(decision), callback_data: "perm:#{id}:#{Prompt.token(decision)}"}]
      end)

    Req.post(api_url(token(), "sendMessage"),
      json: %{
        chat_id: chat_id,
        text: text,
        parse_mode: "HTML",
        reply_markup: %{inline_keyboard: buttons}
      }
    )
  end

  defp decode_args(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(_raw), do: %{}

  # Human-readable risk hints ("⚠️ runs embedded code") above the call preview.
  defp risk_lines(name, map) do
    case Pepe.Permissions.Risk.hints(name, map) do
      [] ->
        ""

      kinds ->
        "\n" <>
          Enum.map_join(kinds, "\n", fn kind ->
            "⚠️ " <> esc(Pepe.Permissions.Risk.label(kind))
          end)
    end
  end

  # The meaningful field to show (command for bash, path for write_file, ...) in a
  # code block - not the raw JSON args.
  defp arg_block(map) when map_size(map) == 0, do: ""
  defp arg_block(map), do: "\n<code>" <> esc(map_preview(map)) <> "</code>"

  defp map_preview(%{"command" => c}) when is_binary(c), do: clip(c)
  defp map_preview(%{"path" => p}) when is_binary(p), do: clip(p)
  defp map_preview(%{"file" => f}) when is_binary(f), do: clip(f)
  defp map_preview(%{"url" => u}) when is_binary(u), do: clip(u)
  defp map_preview(%{"to" => t}) when is_binary(t), do: clip(t)

  defp map_preview(%{"code" => c} = m) when is_binary(c),
    do: "[" <> to_string(m["language"] || "code") <> "] " <> clip(c)

  defp map_preview(map), do: clip(Jason.encode!(map))

  defp clip(text) do
    one = text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(one) > 300, do: String.slice(one, 0, 299) <> "...", else: one
  end

  # "perm:<id>:<token>" -> wake the waiting session and tidy the message.
  defp deliver_permission("perm:" <> rest, cq) do
    case String.split(rest, ":") do
      [id_str, token] ->
        id = String.to_integer(id_str)
        decision = Prompt.from_token(token)

        case :ets.take(@pending, id) do
          [{^id, pid}] ->
            # close_prompt/2 inserts into @prompt_log before send/2 wakes the
            # waiting session - if send ran first, a turn that finishes fast
            # enough could run cleanup_prompts/1 before the insert lands,
            # missing this round's cleanup (self-heals next turn, but avoid it).
            close_prompt(cq, decision)
            send(pid, {:perm_reply, id, decision})

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # Replace the prompt's buttons with the shared outcome text so the chat stays tidy.
  defp close_prompt(cq, decision) do
    Config.put_locale()
    chat_id = get_in(cq, ["message", "chat", "id"])
    message_id = get_in(cq, ["message", "message_id"])

    if chat_id && message_id do
      :ets.insert(@prompt_log, {chat_id, message_id})

      Req.post(api_url(token(), "editMessageText"),
        json: %{chat_id: chat_id, message_id: message_id, text: Prompt.outcome(decision)}
      )
    end
  end

  defp answer_callback(nil), do: :ok

  defp answer_callback(callback_id) do
    Req.post(api_url(token(), "answerCallbackQuery"), json: %{callback_query_id: callback_id})
  end

  ###
  ### commands
  ###

  defp run_command(chat_id, cmd, _args) when cmd in ["new", "reset"] do
    ensure_session(chat_id)
    Pepe.Agent.Session.reset(session_key(chat_id))
    send_message(chat_id, gettext("🧠 New conversation started."))
  end

  defp run_command(chat_id, "undo", _args) do
    ensure_session(chat_id)
    Pepe.Agent.Session.undo(session_key(chat_id))
    send_message(chat_id, gettext("↩️ Undid your last message."))
  end

  # A per-chat waiver of the group @mention requirement (see addressed?/3) - lives
  # on the session, so it's scoped to this chat only and forgotten on /new. No-op
  # in DMs and in groups where require_mention is already off; harmless either way.
  defp run_command(chat_id, "mention", args) do
    ensure_session(chat_id)
    key = session_key(chat_id)

    case args |> String.trim() |> String.downcase() do
      "off" ->
        Pepe.Agent.Session.set_mention_optional(key, true)
        send_message(chat_id, gettext("👂 I'll reply here without being @mentioned, until /new."))

      "on" ->
        Pepe.Agent.Session.set_mention_optional(key, false)
        send_message(chat_id, gettext("📣 @mention required again in this chat."))

      _ ->
        status =
          if Pepe.Agent.Session.mention_optional?(key),
            do: gettext("off (I reply without being mentioned)"),
            else: gettext("on (I need an @mention)")

        send_message(chat_id, gettext("Mention requirement is currently: %{status}.\nUse /mention on or /mention off.", status: status))
    end
  end

  defp run_command(chat_id, "compact", _args) do
    ensure_session(chat_id)
    send_chat_action(chat_id, "typing")

    case Pepe.Agent.Session.compact(session_key(chat_id)) do
      {:ok, _summary} ->
        send_message(chat_id, gettext("🗜️ History compacted."))

      {:error, reason} ->
        Logger.warning("[telegram] compact error: #{safe_inspect(reason)}")
        send_message(chat_id, gettext("I couldn't summarize right now. Try again shortly?"))
    end
  end

  defp run_command(chat_id, "agent", "") do
    send_message(chat_id, gettext("Usage: /agent <name>"))
  end

  defp run_command(chat_id, "agent", name) do
    if Config.get_agent(name) do
      ensure_session(chat_id)
      Pepe.Agent.Session.set_agent(session_key(chat_id), name)
      send_message(chat_id, gettext("Switched to agent %{name}.", name: name))
    else
      send_message(chat_id, gettext("Unknown agent: %{name}", name: name))
    end
  end

  defp run_command(chat_id, "status", _args) do
    ensure_session(chat_id)
    s = Pepe.Agent.Session.status(session_key(chat_id))

    send_message(
      chat_id,
      gettext("Agent: %{agent}\nModel: %{model}\nTurns: %{turns}",
        agent: s.agent || gettext("(default)"),
        model: s.model || gettext("(unset)"),
        turns: s.turns
      )
    )
  end

  defp run_command(chat_id, "models", _args), do: send_model_picker(chat_id)

  defp run_command(chat_id, "model", args) do
    case String.split(args, ~r/\s+/, trim: true) do
      [] -> show_model(chat_id)
      [name] -> change_model(chat_id, name, nil)
      [name, scope] -> change_model(chat_id, name, scope)
      _ -> send_message(chat_id, gettext("Usage: /model NAME [session|global]"))
    end
  end

  defp run_command(chat_id, "tools", _args), do: send_html(chat_id, tools_text())

  defp run_command(chat_id, "learn", _args) do
    if learn?() do
      ensure_session(chat_id)

      case Pepe.Agent.Session.learn(session_key(chat_id)) do
        :ok -> send_message(chat_id, gettext("🧠 Reviewing what I learned..."))
        {:error, :not_allowed} -> send_message(chat_id, gettext("Learning is off for this chat."))
        _ -> send_message(chat_id, gettext("No agent to learn with."))
      end
    else
      send_message(chat_id, gettext("Learning is off for this chat."))
    end
  end

  defp run_command(chat_id, "stop", _args) do
    ensure_session(chat_id)

    case Pepe.Agent.Session.stop(session_key(chat_id)) do
      :ok -> send_message(chat_id, gettext("🛑 Stopped."))
      _ -> send_message(chat_id, gettext("Nothing is running right now."))
    end
  end

  defp run_command(chat_id, "skill", ""), do: send_html(chat_id, skills_text())
  defp run_command(chat_id, "skill", name), do: run_skill(chat_id, name, "")

  defp run_command(chat_id, "approve", args) do
    manage_approvals(chat_id, String.split(args))
  end

  defp run_command(chat_id, cmd, "") when cmd in ["btw", "side"] do
    send_message(chat_id, gettext("Usage: /btw <question>"))
  end

  defp run_command(chat_id, cmd, question) when cmd in ["btw", "side"] do
    ensure_session(chat_id)
    send_chat_action(chat_id, "typing")
    agent = agent_default()

    case Pepe.Agent.aside(session_key(chat_id), agent, question, authorize: authorizer(chat_id)) do
      {:ok, reply} ->
        send_message(chat_id, reply)

      {:error, reason} ->
        Logger.warning("[telegram] aside error: #{safe_inspect(reason)}")
        send_message(chat_id, friendly_error(reason))
    end

    cleanup_prompts(chat_id)
  end

  defp run_command(chat_id, "start", _args) do
    send_message(chat_id, gettext("🧠 Pepe ready.") <> "\n\n" <> help_text())
  end

  defp run_command(chat_id, "help", _args), do: send_message(chat_id, help_text())

  # An unknown command might be a skill exposed as a slash command.
  defp run_command(chat_id, other, args) do
    case skill_for_command(other) do
      nil ->
        send_message(
          chat_id,
          gettext("Unknown command: /%{cmd}", cmd: other) <> "\n\n" <> help_text()
        )

      skill_name ->
        run_skill(chat_id, skill_name, args)
    end
  end

  defp help_text do
    gettext("Commands:") <>
      "\n" <> Enum.map_join(full_menu(), "\n", fn {n, d} -> "/#{n} - #{d}" end)
  end

  ###
  ### command helpers
  ###

  # /whoami - surface the ids needed to fill the allowlists in config.
  defp whoami(chat_id, user_id) do
    send_message(
      chat_id,
      gettext("Your user id: %{user}\nThis chat id: %{chat}", user: user_id, chat: chat_id)
    )
  end

  defp show_model(chat_id) do
    ensure_session(chat_id)
    s = Pepe.Agent.Session.status(session_key(chat_id))
    model = s.model || gettext("(unset)")

    text =
      gettext("Current: %{model}", model: model) <>
        "\n\n" <>
        gettext("Tap below to browse models, or use:") <>
        "\n/model <name> [session|global] - " <>
        gettext("switch") <>
        "\n/models - " <> gettext("list them all")

    Req.post(api_url(token(), "sendMessage"),
      json: %{
        chat_id: chat_id,
        text: text,
        reply_markup: %{inline_keyboard: [[%{text: gettext("Browse models"), callback_data: "model:browse"}]]}
      }
    )
  end

  # `learn?/0` is already computed per-message from the bot's `trainers` allowlist
  # (see `learn_allowed?/1`/`put_learn/1`) - the same list gates memory AND, here,
  # who may change the model globally. Only valid from the `respond/4` path (a
  # typed `/model ...`) - a button tap recomputes it fresh via `learns_from?/2`
  # instead, see `handle_model_callback/4`.
  defp change_model(chat_id, name, scope) do
    ensure_session(chat_id)
    perm = ModelSwitch.permission(learn?(), bot()["model_switch_locked"] == true)
    deliver = fn text -> send_message(chat_id, text) end

    cond do
      is_nil(Config.get_model(name)) ->
        deliver.(gettext("Unknown model: %{name}", name: name))

      perm == :none ->
        deliver.(gettext("You don't have permission to change the model here."))

      perm == :session or scope == "session" ->
        report_model_change(name, :session, session_key(chat_id), agent_default(), deliver)

      scope == "global" ->
        report_model_change(name, :global, session_key(chat_id), agent_default(), deliver)

      scope in [nil, ""] ->
        deliver.(
          gettext(
            "Change to %{name} for this conversation only, or for everyone? Reply /model %{name} session or /model %{name} global.",
            name: name
          )
        )

      true ->
        deliver.(gettext("Usage: /model NAME [session|global]"))
    end
  end

  # Shared by the typed `/model NAME [scope]` and the button-tap flow below -
  # `deliver` is a 1-arity function so each caller decides how the outcome is
  # shown (a new message vs. editing the picker message in place).
  defp report_model_change(name, scope, session_key, agent, deliver) do
    case ModelSwitch.apply(session_key, agent, name, scope) do
      :ok ->
        deliver.(gettext("Model set to %{name} (%{scope}).", name: name, scope: scope_label(scope)))

      {:error, :unknown_model} ->
        deliver.(gettext("Unknown model: %{name}", name: name))

      {:error, :unknown_agent} ->
        deliver.(gettext("There's no agent to set the model on."))
    end
  end

  defp scope_label(:session), do: gettext("this conversation only")
  defp scope_label(:global), do: gettext("everyone")

  ###
  ### the /models picker (inline keyboard)
  ###

  # Same upstream id shown twice (two connections pointing at the same model) would
  # both get a checkmark - a harmless cosmetic edge case, not worth a bigger lookup
  # just to compare by connection name instead.
  defp send_model_picker(chat_id) do
    ensure_session(chat_id)

    case ModelSwitch.list_for(Company.of(agent_default())) do
      [] ->
        send_message(chat_id, gettext("No models are configured for this company."))

      models ->
        current = Pepe.Agent.Session.status(session_key(chat_id)).model

        Req.post(api_url(token(), "sendMessage"),
          json: %{
            chat_id: chat_id,
            text: models_picker_text(models),
            reply_markup: %{inline_keyboard: model_buttons(models, current)}
          }
        )
    end
  end

  defp edit_model_picker(chat_id, message_id) do
    ensure_session(chat_id)

    case ModelSwitch.list_for(Company.of(agent_default())) do
      [] ->
        edit_message(chat_id, message_id, gettext("No models are configured for this company."))

      models ->
        current = Pepe.Agent.Session.status(session_key(chat_id)).model
        edit_message(chat_id, message_id, models_picker_text(models), model_buttons(models, current))
    end
  end

  defp models_picker_text(models),
    do: gettext("Available models") <> " — #{length(models)}"

  defp model_buttons(models, current) do
    Enum.map(models, fn m ->
      label = if m.model == current, do: "#{m.name} ✓", else: m.name
      [%{text: label, callback_data: "model:pick:#{m.name}"}]
    end)
  end

  # "model:pick:<name>" - tapped a model. A `:session`-only presser has nothing to
  # choose, so it applies right away; a trainer (`:global`) is offered the
  # session-vs-everyone submenu; `:none` is refused.
  defp handle_model_callback(chat_id, message_id, user_id, "model:pick:" <> name) do
    ensure_session(chat_id)
    perm = ModelSwitch.permission(learns_from?(bot(), user_id), bot()["model_switch_locked"] == true)

    cond do
      is_nil(Config.get_model(name)) ->
        edit_message(chat_id, message_id, gettext("Unknown model: %{name}", name: name))

      perm == :none ->
        edit_message(chat_id, message_id, gettext("You don't have permission to change the model here."))

      perm == :session ->
        deliver = fn text -> edit_message(chat_id, message_id, text) end
        report_model_change(name, :session, session_key(chat_id), agent_default(), deliver)

      perm == :global ->
        edit_model_scope_picker(chat_id, message_id, name)
    end
  end

  # "model:apply:<name>:<scope>" - tapped a scope in the submenu. Permission is
  # rechecked (never trust the tap alone - config may have changed since the
  # picker was sent).
  defp handle_model_callback(chat_id, message_id, user_id, "model:apply:" <> rest) do
    ensure_session(chat_id)
    perm = ModelSwitch.permission(learns_from?(bot(), user_id), bot()["model_switch_locked"] == true)
    deliver = fn text -> edit_message(chat_id, message_id, text) end

    case {String.split(rest, ":", parts: 2), perm} do
      {[name, "session"], p} when p in [:session, :global] ->
        report_model_change(name, :session, session_key(chat_id), agent_default(), deliver)

      {[name, "global"], :global} ->
        report_model_change(name, :global, session_key(chat_id), agent_default(), deliver)

      _ ->
        deliver.(gettext("You don't have permission to change the model here."))
    end
  end

  defp handle_model_callback(chat_id, message_id, _user_id, cb) when cb in ["model:back", "model:browse"] do
    edit_model_picker(chat_id, message_id)
  end

  defp handle_model_callback(_chat_id, _message_id, _user_id, _data), do: :ok

  defp edit_model_scope_picker(chat_id, message_id, name) do
    buttons = [
      [%{text: gettext("This conversation only"), callback_data: "model:apply:#{name}:session"}],
      [%{text: gettext("Everyone"), callback_data: "model:apply:#{name}:global"}],
      [%{text: gettext("<< Back"), callback_data: "model:back"}]
    ]

    edit_message(
      chat_id,
      message_id,
      gettext("Change to %{name} for this conversation only, or for everyone?", name: name),
      buttons
    )
  end

  defp edit_message(chat_id, message_id, text, buttons \\ nil) do
    body = %{chat_id: chat_id, message_id: message_id, text: text}
    body = if buttons, do: Map.put(body, :reply_markup, %{inline_keyboard: buttons}), else: body
    Req.post(api_url(token(), "editMessageText"), json: body)
  end

  defp tools_text do
    body =
      Pepe.Tools.all()
      |> Enum.map(fn mod -> {mod.name(), tool_label(mod)} end)
      |> Enum.sort()
      |> Enum.map_join("\n\n", fn {name, desc} -> "• " <> htmlb(name) <> " - " <> esc(desc) end)

    htmlb(gettext("Available tools")) <> "\n\n" <> body
  end

  # Display text for a tool: a translated one-liner for built-ins, falling back to
  # the (English) spec description's first sentence for plugins.
  defp tool_label(mod), do: tool_summary(mod.name()) || short_desc(tool_desc(mod))

  defp tool_desc(mod), do: mod.spec() |> get_in(["function", "description"]) |> to_string()

  # Translated one-liners for the built-in tools (names are never translated). An
  # unknown name (e.g. a plugin) returns nil so the caller falls back to the spec.
  defp tool_summary("bash"), do: gettext("Run a shell command and return its output.")
  defp tool_summary("run_script"), do: gettext("Write and run a program for complex tasks.")
  defp tool_summary("read_file"), do: gettext("Read a text file.")
  defp tool_summary("write_file"), do: gettext("Create or overwrite a file.")
  defp tool_summary("edit_file"), do: gettext("Replace text in a file.")
  defp tool_summary("move_file"), do: gettext("Move or rename a file or directory.")
  defp tool_summary("list_dir"), do: gettext("List files in a directory.")
  defp tool_summary("fetch_url"), do: gettext("Fetch a URL (HTTP GET).")
  defp tool_summary("web_search"), do: gettext("Search the web.")
  defp tool_summary("skill"), do: gettext("Read a skill (a how-to guide).")
  defp tool_summary("send_to_agent"), do: gettext("Send a message to another agent.")
  defp tool_summary("rename_agent"), do: gettext("Rename yourself (this agent).")
  defp tool_summary("config_get"), do: gettext("Read the Pepe configuration.")
  defp tool_summary("config_set"), do: gettext("Change a Pepe setting.")
  defp tool_summary("enable_tool"), do: gettext("Enable a tool for yourself.")
  defp tool_summary("set_route"), do: gettext("Add or remove an agent-to-agent route.")
  defp tool_summary(_other), do: nil

  # Translated one-liners for the built-in skills, shown in the "/" menu and the
  # /skill list (in the configured language). User skills fall back to their own
  # first line (nil here).
  defp skill_summary("install-tool"), do: gettext("How to install a new tool when asked.")

  defp skill_summary("install-skill"),
    do: gettext("Install a skill from a URL, with a security review first.")

  defp skill_summary("handle-media"),
    do: gettext("Understand a voice/audio/image/file the user sent.")

  defp skill_summary("manage-routing"), do: gettext("Change which agents can message each other.")
  defp skill_summary("skill-creator"), do: gettext("Create, edit, audit or improve a skill.")

  defp skill_summary("write-a-script"),
    do: gettext("Tackle a complex task by writing and running a script.")

  defp skill_summary(_other), do: nil

  # First sentence of a description, trimmed - keeps the tool list scannable.
  defp short_desc(text) do
    first =
      text
      |> String.trim()
      |> String.split(~r/(?<=\.)\s/, parts: 2)
      |> List.first()
      |> to_string()

    if String.length(first) > 110, do: String.slice(first, 0, 109) <> "...", else: first
  end

  defp skills_text do
    case Pepe.Skills.list() do
      [] ->
        gettext("No skills are available yet.")

      skills ->
        htmlb(gettext("Available skills (run with /skill <name>):")) <>
          "\n\n" <>
          Enum.map_join(skills, "\n\n", fn {name, summary} ->
            "• " <> htmlb(name) <> " - " <> esc(skill_summary(name) || summary)
          end)
    end
  end

  # Run a skill by handing the agent an instruction to carry it out; it reads the
  # skill via its `skill` tool and follows the steps (replying in the user's tongue).
  defp run_skill(chat_id, name, args) do
    case Pepe.Skills.read(name) do
      {:error, _reason} ->
        send_message(chat_id, gettext("Unknown skill: %{name}", name: name))

      {:ok, _content} ->
        extra = if args == "", do: "", else: "\n\nInput: #{args}"
        chat_with_agent(chat_id, nil, "Carry out the \"#{name}\" skill now." <> extra)
    end
  end

  # /approve - inspect or clear the agent's persistent ("always allow") grants.
  defp manage_approvals(chat_id, []) do
    agent_name = agent_default()

    case Config.get_agent(agent_name) do
      nil ->
        send_message(chat_id, gettext("No agent is configured."))

      %{auto_approve: []} ->
        send_message(chat_id, gettext("Nothing is pre-approved - I'll ask before risky tools."))

      %{auto_approve: tools} ->
        send_message(
          chat_id,
          gettext("Always allowed (clear with /approve clear <tool>):") <>
            "\n" <> Enum.map_join(tools, "\n", &"• #{&1}")
        )
    end
  end

  defp manage_approvals(chat_id, ["clear"]) do
    update_agent_approvals(
      chat_id,
      fn _agent -> [] end,
      gettext("Cleared all saved permissions.")
    )
  end

  defp manage_approvals(chat_id, ["clear", tool]) do
    update_agent_approvals(
      chat_id,
      fn agent -> List.delete(agent.auto_approve, tool) end,
      gettext("Removed %{tool}.", tool: tool)
    )
  end

  defp manage_approvals(chat_id, _other) do
    send_message(chat_id, gettext("Usage: /approve  ·  /approve clear  ·  /approve clear <tool>"))
  end

  defp update_agent_approvals(chat_id, fun, ok_message) do
    agent_name = agent_default()

    case Config.get_agent(agent_name) do
      nil ->
        send_message(chat_id, gettext("No agent is configured."))

      agent ->
        Config.put_agent(%{agent | auto_approve: fun.(agent)})
        send_message(chat_id, ok_message)
    end
  end

  # The default bot keeps the legacy `telegram:<chat_id>` key so existing sessions
  # and bindings survive; named bots are namespaced to avoid collisions and to let
  # cron delivery route back to the right bot.
  defp session_key(chat_id), do: session_key(bot_name(), chat_id)
  defp session_key("default", chat_id), do: "telegram:#{chat_id}"
  defp session_key(name, chat_id), do: "telegram:#{name}:#{chat_id}"

  defp ensure_session(chat_id) do
    agent = agent_default()
    Pepe.Agent.SessionSupervisor.ensure(session_key(chat_id), agent)
  end

  @doc """
  Public entry point for delivering an unsolicited message to a chat (used by the
  scheduled-task engine to report cron results). `target` is the part after
  `"telegram:"` in a delivery address: `"<chat_id>"` (the default bot) or
  `"<bot_name>:<chat_id>"` (a named bot). No-op when the bot/token can't be found.
  """
  def deliver(target, text) do
    case resolve_delivery(target) do
      {bot, chat_id} ->
        put_bot(bot)
        if token(), do: send_message(chat_id, text)

      :error ->
        Logger.warning("[telegram] no bot to deliver to #{inspect(target)}")
    end

    :ok
  end

  @doc "Send a local file as a Telegram document to `target` (a session/delivery key)."
  def deliver_file(target, path, caption \\ nil) do
    case resolve_delivery(target) do
      {bot, chat_id} ->
        put_bot(bot)
        if token(), do: send_document(chat_id, path, caption), else: {:error, :no_token}

      :error ->
        {:error, :no_bot}
    end
  end

  defp send_document(chat_id, path, caption) do
    fields =
      [chat_id: to_string(chat_id)]
      |> then(fn f -> if caption in [nil, ""], do: f, else: f ++ [caption: caption] end)
      |> Kernel.++(document: {File.stream!(path), filename: Path.basename(path)})

    case Req.post(api_url(token(), "sendDocument"), form_multipart: fields, receive_timeout: 120_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:telegram, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_delivery(target) do
    case String.split(to_string(target), ":", parts: 2) do
      [name, chat_id] ->
        case Config.telegram_bot(name) do
          nil -> :error
          bot -> {bot, chat_id}
        end

      [chat_id] ->
        case Config.telegram_bot("default") || List.first(Config.telegram_bots()) do
          nil -> :error
          bot -> {bot, chat_id}
        end
    end
  end

  ###
  ### live activity layer
  ###

  # An `on_event` callback that renders the agent's tool activity into a single
  # status message which updates in place as tools run, then deletes itself when the
  # run finishes - so only the final answer stays in the chat. Runs in the run task
  # process, so it re-installs this bot and keeps its state in that process dict.
  defp activity_callback(chat_id) do
    b = bot()

    fn event ->
      put_bot(b)
      tg_activity(chat_id, event)
    end
  end

  @tool_running "🛠️"
  @tool_done "✅"

  # How much of the agent's tool activity to surface, per bot (`"tool_progress"`):
  #   * "reaction" - (default) NO message at all; just a 👀 reaction on the user's own
  #     message while working, cleared when the answer lands. The quietest signal.
  #   * "ambient"  - a single vague "what kind of work is happening" line, edited in
  #     place; no tool names, args or per-step ledger.
  #   * "off"      - nothing but the native typing indicator.
  #   * "verbose"  - the detailed per-tool breadcrumb list (for power users).
  # The message-based modes use one message, edited in place, deleted when done.
  defp progress_mode, do: bot()["tool_progress"] || "reaction"

  defp tg_activity(chat_id, {:tool_call, name, raw}) do
    case progress_mode() do
      "verbose" -> verbose_tool(chat_id, name, raw)
      "ambient" -> ambient_tool(chat_id, name)
      # "off" and "reaction" show no status message (reaction is set around the run).
      _ -> :ok
    end
  end

  defp tg_activity(chat_id, {:tool_result, _name, _out}) do
    if progress_mode() == "verbose", do: verbose_result(chat_id), else: :ok
  end

  defp tg_activity(chat_id, event) when elem(event, 0) in [:done, :error] do
    if id = Process.get(:tg_act_id), do: delete_status(chat_id, id)
    Process.delete(:tg_act_id)
    Process.delete(:tg_act_lines)
    Process.delete(:tg_act_phrase)
    :ok
  end

  defp tg_activity(_chat_id, _event), do: :ok

  # Ambient: one loose phrase for the *kind* of work, re-edited only when it changes.
  defp ambient_tool(chat_id, name) do
    phrase = ambient_phrase(name)

    if Process.get(:tg_act_phrase) != phrase do
      Process.put(:tg_act_phrase, phrase)
      render_activity(chat_id, phrase)
    end

    :ok
  end

  defp ambient_phrase(name) do
    cond do
      name == "web_search" ->
        "🔎 " <> gettext("looking things up...")

      name == "fetch_url" ->
        "🌐 " <> gettext("fetching a page...")

      name in ["bash", "run_script"] ->
        "💻 " <> gettext("running something...")

      name in ~w(read_file write_file edit_file list_dir move_file) ->
        "📄 " <> gettext("working with files...")

      name == "send_to_agent" ->
        "💬 " <> gettext("checking with another agent...")

      String.starts_with?(name, "mcp__") ->
        "🧰 " <> gettext("using a connected tool...")

      true ->
        "⚙️ " <> gettext("working on it...")
    end
  end

  # Verbose: the per-tool breadcrumb ledger, edited in place; a result marks the last
  # line done.
  defp verbose_tool(chat_id, name, raw) do
    lines = (Process.get(:tg_act_lines, []) ++ [activity_line(name, raw)]) |> Enum.take(-6)
    Process.put(:tg_act_lines, lines)
    render_activity(chat_id, Enum.join(lines, "\n"))
  end

  defp verbose_result(chat_id) do
    lines = Process.get(:tg_act_lines, []) |> mark_last_done()
    Process.put(:tg_act_lines, lines)
    render_activity(chat_id, Enum.join(lines, "\n"))
  end

  # One status message per turn: send it the first time (with the real text, no
  # placeholder flash), then edit it in place. Id stored in the run task's dict.
  defp render_activity(chat_id, text) do
    case Process.get(:tg_act_id) do
      nil -> if id = send_status(chat_id, text), do: Process.put(:tg_act_id, id)
      id -> edit_status(chat_id, id, text)
    end

    :ok
  end

  defp mark_last_done([]), do: []

  defp mark_last_done(lines) do
    {init, [last]} = Enum.split(lines, -1)
    init ++ [String.replace_prefix(last, @tool_running, @tool_done)]
  end

  defp activity_line(name, raw) do
    case decode_args(raw) do
      map when map_size(map) > 0 -> @tool_running <> " " <> name <> " · " <> map_preview(map)
      _ -> @tool_running <> " " <> name
    end
  end

  defp send_status(chat_id, text) do
    case Req.post(api_url(token(), "sendMessage"), json: %{chat_id: chat_id, text: text}) do
      {:ok, %{status: 200, body: %{"result" => %{"message_id" => id}}}} -> id
      _ -> nil
    end
  end

  defp edit_status(chat_id, id, text) do
    Req.post(api_url(token(), "editMessageText"),
      json: %{chat_id: chat_id, message_id: id, text: text}
    )
  end

  defp delete_status(chat_id, id) do
    Req.post(api_url(token(), "deleteMessage"), json: %{chat_id: chat_id, message_id: id})
  end

  defp send_message(chat_id, text) do
    unless dead_target?(chat_id) do
      # Telegram caps messages at 4096 chars. Chunk the plain text, then render each
      # chunk as HTML so a split never lands inside a tag.
      text
      |> chunk(4000)
      |> Enum.each(fn part -> post_part(chat_id, part) end)
    end
  end

  # Send one chunk as Telegram HTML (so **bold**/`code`/links render); if the API
  # rejects the formatting, resend it as plain text so the message still arrives.
  defp post_part(chat_id, part) do
    url = api_url(token(), "sendMessage")
    html = Pepe.Gateways.Telegram.Markdown.to_html(part)
    result = Req.post(url, json: %{chat_id: chat_id, text: html, parse_mode: "HTML"})

    case result do
      {:ok, %{status: 200}} ->
        track_delivery(result, chat_id)

      _ ->
        url |> Req.post(json: %{chat_id: chat_id, text: part}) |> track_delivery(chat_id)
    end
  end

  # Send an HTML-formatted message (bold names, etc.). Callers must escape dynamic
  # text with `esc/1`; `htmlb/1` does both (escape + bold).
  defp send_html(chat_id, text) do
    unless dead_target?(chat_id) do
      text
      |> chunk(4000)
      |> Enum.each(fn part ->
        api_url(token(), "sendMessage")
        |> Req.post(json: %{chat_id: chat_id, text: part, parse_mode: "HTML"})
        |> track_delivery(chat_id)
      end)
    end
  end

  # Self-healing dead-target tracking: skip a chat we already know is gone;
  # otherwise send and mark it dead/alive from the actual response, so a target
  # recovers automatically (e.g. the user un-blocked the bot) with no manual reset.
  defp dead_target?(chat_id), do: Pepe.Gateways.Reachability.dead?(bot_name(), chat_id)

  defp track_delivery(response, chat_id) do
    if Pepe.Gateways.Reachability.permanent_failure?(response) do
      Logger.info("[telegram] marking chat #{chat_id} dead (permanent delivery failure)")
      Pepe.Gateways.Reachability.mark_dead(bot_name(), chat_id)
    else
      Pepe.Gateways.Reachability.clear(bot_name(), chat_id)
    end

    response
  end

  defp htmlb(text), do: "<b>" <> esc(text) <> "</b>"

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Telegram's "typing..." bubble lasts only ~5s, so a long non-streaming turn (slow
  # model, no tool calls) would look frozen after the first hint. Keep it alive by
  # re-sending the action every few seconds until the run finishes. Linked to the run
  # task (so a crash tears it down) but stopped explicitly, since a normal task exit
  # doesn't kill a linked child.
  defp keep_typing(chat_id) do
    b = bot()

    spawn_link(fn ->
      put_bot(b)
      typing_loop(chat_id)
    end)
  end

  defp typing_loop(chat_id) do
    send_chat_action(chat_id, "typing")

    receive do
      :stop -> :ok
    after
      4_000 -> typing_loop(chat_id)
    end
  end

  defp stop_typing(pid) when is_pid(pid), do: send(pid, :stop)

  # Set (or, with nil, clear) a reaction on a message. Fire-and-forget: if reactions
  # are disabled in the chat the call just fails harmlessly and the typing hint remains.
  defp set_reaction(_chat_id, nil, _emoji), do: :ok

  defp set_reaction(chat_id, msg_id, emoji) do
    reaction = if emoji, do: [%{type: "emoji", emoji: emoji}], else: []

    Req.post(api_url(token(), "setMessageReaction"),
      json: %{chat_id: chat_id, message_id: msg_id, reaction: reaction}
    )

    :ok
  end

  defp send_chat_action(chat_id, action) do
    Req.post(api_url(token(), "sendChatAction"), json: %{chat_id: chat_id, action: action})
  end

  defp chunk(text, size) do
    case String.length(text) do
      0 -> [gettext("(empty response)")]
      n when n <= size -> [text]
      _ -> text |> String.to_charlist() |> Enum.chunk_every(size) |> Enum.map(&List.to_string/1)
    end
  end

  # The bot's `enabled` flag - lets you pause it without deleting the token.
  defp active?, do: bot()["enabled"] != false

  # Both the chat and the user must clear this bot's (optional) allowlists. An empty
  # or missing list means "no restriction" on that dimension.
  defp allowed?(chat_id, user_id) do
    tg = bot()
    allowlisted?(tg["allowed_chats"], chat_id) and allowlisted?(tg["allowed_users"], user_id)
  end

  defp allowlisted?(list, id) when is_list(list) and list != [], do: id in list
  defp allowlisted?(_no_restriction, _id), do: true

  # DMs always reach the agent. In groups, optionally require an @mention (or a
  # /command) so the bot doesn't answer every message - unless this chat waived
  # that for itself with /mention (see mention_waived?/1).
  defp addressed?(_text, "private", _chat_id), do: true

  defp addressed?(text, _group, chat_id) do
    if require_mention?() do
      mentions_bot?(text) or command?(text) or mention_waived?(chat_id)
    else
      true
    end
  end

  defp require_mention?, do: bot()["require_mention"] != false

  # A session-scoped, per-chat waiver of the mention requirement above - lives on
  # the session (not the bot, unlike require_mention? itself), so /mention only
  # affects the group it was run in, and resets with the conversation (/new).
  defp mention_waived?(chat_id) do
    ensure_session(chat_id)
    Pepe.Agent.Session.mention_optional?(session_key(chat_id))
  end

  @doc """
  Whether a conversation may feed the memory/skill review, from a bot's `trainers`
  allowlist: missing/null = learns from everyone, `[]` = learns from no one,
  `[ids]` = learns only from those user ids. So a client's chat on a client-facing
  bot never becomes memory.
  """
  def learns_from?(bot, user_id) when is_map(bot) do
    case bot["trainers"] do
      nil -> true
      [] -> false
      list when is_list(list) -> "*" in list or user_id in list
      _ -> true
    end
  end

  defp learn_allowed?(user_id), do: learns_from?(bot(), user_id)

  # Stashed for this task process so downstream helpers (chat_with_agent, /learn)
  # see the decision without threading user_id everywhere.
  defp put_learn(allowed?), do: Process.put(:pepe_tg_learn, allowed?)
  defp learn?, do: Process.get(:pepe_tg_learn, true)
  defp command?(text), do: String.starts_with?(text, "/")

  defp mentions_bot?(text) do
    case bot_username() do
      nil -> true
      username -> String.contains?(text, "@" <> username)
    end
  end

  # Drop the "@botname" so the agent sees a clean prompt.
  defp strip_mention(text) do
    case bot_username() do
      nil -> text
      username -> text |> String.replace("@" <> username, "") |> String.trim()
    end
  end

  # Cache the bot's @username (from getMe) for mention handling.
  defp bot_username do
    key = {__MODULE__, :username, bot_name()}

    case :persistent_term.get(key, :unset) do
      :unset ->
        username = fetch_username()
        :persistent_term.put(key, username)
        username

      username ->
        username
    end
  end

  defp fetch_username do
    case Req.get(api_url(token(), "getMe")) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"username" => username}}}} ->
        username

      _ ->
        nil
    end
  end
end
