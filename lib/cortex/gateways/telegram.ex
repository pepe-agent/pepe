defmodule Cortex.Gateways.Telegram do
  @moduledoc """
  Telegram gateway via long polling (`getUpdates`). Each chat maps to a persistent
  Cortex session, so conversations keep context — talk to your agent from Telegram
  while it works.

  Configuration (in `~/.cortex/config.json` under `"telegram"`):

      {
        "bot_token": "${TELEGRAM_BOT_TOKEN}",
        "enabled": true,               // optional; false disables without deleting
        "allowed_chats": [12345],      // optional chat allowlist; empty = any chat
        "allowed_users": [67890],      // optional user allowlist; empty = any user
        "require_mention": true,       // optional; in groups only reply when @mentioned
        "agent": "assistant"           // optional agent override
      }
  """
  use GenServer
  use Gettext, backend: Cortex.Gettext

  require Logger

  alias Cortex.Config
  alias Cortex.Permissions.Prompt

  @poll_timeout 30

  # Pending permission prompts: request_id => the waiting session pid. Lives in a
  # public ETS table so the poll loop (this process) can answer a `receive` that's
  # blocking in a Session process.
  @pending :cortex_tg_pending
  # How long to wait for a button press before denying.
  @perm_timeout 120_000

  # The built-in slash commands. Descriptions are built at runtime so they're
  # translated in the active locale. Installed skills are appended dynamically by
  # `full_menu/0`, so they show up in Telegram's "/" popup too.
  @spec menu() :: [{String.t(), String.t()}]
  defp menu do
    [
      {"new", gettext("Start a fresh conversation")},
      {"undo", gettext("Undo your last message")},
      {"compact", gettext("Summarize history to free up context")},
      {"agent", gettext("Switch agent — /agent <name>")},
      {"model", gettext("Show or set the model — /model <name>")},
      {"models", gettext("List configured models")},
      {"tools", gettext("List available runtime tools")},
      {"skill", gettext("List or run a skill — /skill <name>")},
      {"approve", gettext("Manage saved tool permissions — /approve")},
      {"status", gettext("Show session info")},
      {"whoami", gettext("Show your Telegram ids")},
      {"btw", gettext("Ask a side question that isn't saved — /btw <q>")},
      {"learn", gettext("Save what I learned to memory/skills")},
      {"stop", gettext("Stop the current run")},
      {"help", gettext("List commands")}
    ]
  end

  # Built-in commands plus one command per installed skill (so skills are
  # discoverable from the "/" menu, the way reference surfaces them).
  @spec full_menu() :: [{String.t(), String.t()}]
  defp full_menu, do: menu() ++ skill_commands()

  # Each skill as a `{command, description}`. Names are normalized to Telegram's
  # command charset; any that would collide with a built-in are dropped.
  @spec skill_commands() :: [{String.t(), String.t()}]
  defp skill_commands do
    reserved = MapSet.new(Enum.map(menu(), &elem(&1, 0)))

    Cortex.Skills.list()
    |> Enum.map(fn {name, summary} ->
      {command_name(name), command_desc(skill_summary(name) || summary, name)}
    end)
    |> Enum.reject(fn {cmd, _desc} -> cmd == "" or MapSet.member?(reserved, cmd) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # The skill whose command form matches `cmd`, or nil.
  @spec skill_for_command(String.t()) :: String.t() | nil
  defp skill_for_command(cmd) do
    Enum.find_value(Cortex.Skills.list(), fn {name, _summary} ->
      if command_name(name) == cmd, do: name
    end)
  end

  # Telegram commands: lowercase a–z, digits, underscore, ≤32 chars.
  @spec command_name(String.t()) :: String.t()
  defp command_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 32)
  end

  # Telegram descriptions must be 1–256 chars; fall back to a generic line.
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

  def enabled?, do: not is_nil(token())

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  defp token do
    Config.telegram() |> Map.get("bot_token") |> Cortex.Config.interpolate() |> presence()
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v), do: v

  ###
  ### server
  ###

  @impl true
  def init(_) do
    Logger.info("[telegram] gateway starting")
    # Fresh start: forget any cached bot username (the token may be a new bot).
    :persistent_term.erase({__MODULE__, :username})
    if :ets.whereis(@pending) == :undefined, do: :ets.new(@pending, [:set, :public, :named_table])
    Task.start(&register_commands/0)
    send(self(), :poll)
    {:ok, %{offset: 0}}
  end

  # Scopes Cortex never sets itself. A more-specific scope (e.g. a leftover set by
  # another app that shared this token) overrides our default menu — so we clear
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
    # live — no restart needed (most config is hot-reloaded this way).
    state =
      case token() && get_updates(token(), state.offset) do
        {:ok, updates} ->
          Enum.each(updates, &handle_update/1)
          %{state | offset: next_offset(updates, state.offset)}

        nil ->
          Process.sleep(2_000)
          state

        {:error, reason} ->
          Logger.warning("[telegram] poll error: #{inspect(reason)}")
          Process.sleep(2_000)
          state
      end

    send(self(), :poll)
    {:noreply, state}
  end

  defp next_offset([], offset), do: offset

  defp next_offset(updates, _offset) do
    updates |> Enum.map(& &1["update_id"]) |> Enum.max() |> Kernel.+(1)
  end

  ###
  ### telegram API
  ###

  defp api_url(token, method), do: "https://api.telegram.org/bot#{token}/#{method}"

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

    if active?() and allowed?(chat_id, user_id) and addressed?(text, chat["type"]) do
      Task.start(fn -> respond(chat_id, user_id, strip_mention(text)) end)
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

  # Non-text messages: download the file into the agent's workspace and hand it the
  # path, so it can figure out how to understand it (transcribe, read, …) with its
  # own tools — installing whatever it needs. We don't hardcode transcription.
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

    if active?() and allowed?(chat_id, user_id) and addressed?(caption, chat["type"]) do
      Task.start(fn -> ingest_media(chat_id, file_id, kind, caption) end)
    end
  end

  defp ingest_media(chat_id, file_id, kind, caption) do
    Config.put_locale()
    send_chat_action(chat_id, "typing")

    case download_file(file_id, kind) do
      {:ok, path} ->
        chat_with_agent(chat_id, media_prompt(kind, path, caption))

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
      agent = Config.telegram()["agent"] || Config.default_agent_name()
      dir = Path.join(Cortex.Agent.Workspace.dir(agent), "media")
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
      "The user sent a voice message. The audio is saved in your workspace at `#{path}`. Transcribe it, then respond to what they actually said." <>
        caption_line(caption)

  defp media_prompt("audio", path, caption),
    do:
      "The user sent an audio file, saved at `#{path}`. Transcribe it and respond to its content." <>
        caption_line(caption)

  defp media_prompt("photo", path, caption),
    do:
      "The user sent a photo, saved at `#{path}`. Look at it and respond to what they want." <>
        caption_line(caption)

  defp media_prompt("document", path, caption),
    do:
      "The user sent a file, saved at `#{path}`. Inspect it and help with whatever they need." <>
        caption_line(caption)

  defp caption_line(""), do: ""
  defp caption_line(caption), do: "\n\nTheir caption: #{caption}"

  defp respond(chat_id, user_id, text) do
    Config.put_locale()

    case parse_command(text) do
      # /whoami is the one command that needs the sender id.
      {:command, "whoami", _args} -> whoami(chat_id, user_id)
      {:command, name, args} -> run_command(chat_id, name, args)
      :chat -> chat_with_agent(chat_id, text)
    end
  end

  # "/cmd@botname args" → {:command, "cmd", "args"}; anything else → :chat.
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

  defp chat_with_agent(chat_id, text) do
    send_chat_action(chat_id, "typing")
    agent = Config.telegram()["agent"] || Config.default_agent_name()

    case Cortex.Agent.chat(session_key(chat_id), agent, text, authorize: authorizer(chat_id)) do
      {:ok, reply} ->
        send_message(chat_id, reply)

      {:error, :stopped} ->
        # The user issued /stop; that command already acknowledged it.
        :ok

      {:error, :busy} ->
        send_message(
          chat_id,
          gettext("I'm still on the previous message — send /stop to cancel it.")
        )

      {:error, reason} ->
        # Never leak raw internal errors into the chat — log them, reply kindly.
        Logger.warning("[telegram] chat error: #{inspect(reason)}")
        send_message(chat_id, friendly_error(reason))
    end
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

  defp friendly_error(_),
    do: gettext("Sorry, something went wrong on my end. Try again in a moment?")

  ###
  ### permissions (native inline-button prompt)
  ###

  # The `authorize` callback Cortex calls before a risky tool runs. It executes in
  # the Session process; we render Telegram's own inline keyboard and block until
  # the poll loop delivers the pressed button (or we time out → deny).
  defp authorizer(chat_id) do
    fn name, args, _ctx -> request_authorization(chat_id, name, args) end
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
    case Cortex.Permissions.Risk.hints(name, map) do
      [] ->
        ""

      kinds ->
        "\n" <>
          Enum.map_join(kinds, "\n", fn kind ->
            "⚠️ " <> esc(Cortex.Permissions.Risk.label(kind))
          end)
    end
  end

  # The meaningful field to show (command for bash, path for write_file, …) in a
  # code block — not the raw JSON args.
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
    if String.length(one) > 300, do: String.slice(one, 0, 299) <> "…", else: one
  end

  # "perm:<id>:<token>" → wake the waiting session and tidy the message.
  defp deliver_permission("perm:" <> rest, cq) do
    case String.split(rest, ":") do
      [id_str, token] ->
        id = String.to_integer(id_str)
        decision = Prompt.from_token(token)

        case :ets.take(@pending, id) do
          [{^id, pid}] ->
            send(pid, {:perm_reply, id, decision})
            close_prompt(cq, decision)

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
    Cortex.Agent.Session.reset(session_key(chat_id))
    send_message(chat_id, gettext("🧠 New conversation started."))
  end

  defp run_command(chat_id, "undo", _args) do
    ensure_session(chat_id)
    Cortex.Agent.Session.undo(session_key(chat_id))
    send_message(chat_id, gettext("↩️ Undid your last message."))
  end

  defp run_command(chat_id, "compact", _args) do
    ensure_session(chat_id)
    send_chat_action(chat_id, "typing")

    case Cortex.Agent.Session.compact(session_key(chat_id)) do
      {:ok, _summary} ->
        send_message(chat_id, gettext("🗜️ History compacted."))

      {:error, reason} ->
        Logger.warning("[telegram] compact error: #{inspect(reason)}")
        send_message(chat_id, gettext("I couldn't summarize right now. Try again shortly?"))
    end
  end

  defp run_command(chat_id, "agent", "") do
    send_message(chat_id, gettext("Usage: /agent <name>"))
  end

  defp run_command(chat_id, "agent", name) do
    if Config.get_agent(name) do
      ensure_session(chat_id)
      Cortex.Agent.Session.set_agent(session_key(chat_id), name)
      send_message(chat_id, gettext("Switched to agent %{name}.", name: name))
    else
      send_message(chat_id, gettext("Unknown agent: %{name}", name: name))
    end
  end

  defp run_command(chat_id, "status", _args) do
    ensure_session(chat_id)
    s = Cortex.Agent.Session.status(session_key(chat_id))

    send_message(
      chat_id,
      gettext("Agent: %{agent}\nModel: %{model}\nTurns: %{turns}",
        agent: s.agent || gettext("(default)"),
        model: s.model || gettext("(unset)"),
        turns: s.turns
      )
    )
  end

  defp run_command(chat_id, "models", _args), do: send_html(chat_id, models_text())

  defp run_command(chat_id, "model", ""), do: show_model(chat_id)
  defp run_command(chat_id, "model", name), do: set_model(chat_id, name)

  defp run_command(chat_id, "tools", _args), do: send_html(chat_id, tools_text())

  defp run_command(chat_id, "learn", _args) do
    ensure_session(chat_id)

    case Cortex.Agent.Session.learn(session_key(chat_id)) do
      :ok -> send_message(chat_id, gettext("🧠 Reviewing what I learned…"))
      _ -> send_message(chat_id, gettext("No agent to learn with."))
    end
  end

  defp run_command(chat_id, "stop", _args) do
    ensure_session(chat_id)

    case Cortex.Agent.Session.stop(session_key(chat_id)) do
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
    agent = Config.telegram()["agent"] || Config.default_agent_name()

    case Cortex.Agent.aside(session_key(chat_id), agent, question, authorize: authorizer(chat_id)) do
      {:ok, reply} ->
        send_message(chat_id, reply)

      {:error, reason} ->
        Logger.warning("[telegram] aside error: #{inspect(reason)}")
        send_message(chat_id, friendly_error(reason))
    end
  end

  defp run_command(chat_id, "start", _args) do
    send_message(chat_id, gettext("🧠 Cortex ready.") <> "\n\n" <> help_text())
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
      "\n" <> Enum.map_join(full_menu(), "\n", fn {n, d} -> "/#{n} — #{d}" end)
  end

  ###
  ### command helpers
  ###

  # /whoami — surface the ids needed to fill the allowlists in config.
  defp whoami(chat_id, user_id) do
    send_message(
      chat_id,
      gettext("Your user id: %{user}\nThis chat id: %{chat}", user: user_id, chat: chat_id)
    )
  end

  defp models_text do
    case Config.models() do
      [] ->
        gettext("No models are configured yet.")

      models ->
        htmlb(gettext("Available models")) <>
          "\n" <>
          Enum.map_join(models, "\n", fn m -> "• " <> htmlb(m.name) <> " — " <> esc(m.model) end)
    end
  end

  defp show_model(chat_id) do
    ensure_session(chat_id)
    s = Cortex.Agent.Session.status(session_key(chat_id))

    send_message(
      chat_id,
      gettext("Current model: %{model}", model: s.model || gettext("(unset)"))
    )
  end

  defp set_model(chat_id, name) do
    agent_name = Config.telegram()["agent"] || Config.default_agent_name()

    cond do
      is_nil(Config.get_model(name)) ->
        send_message(chat_id, gettext("Unknown model: %{name}", name: name))

      is_nil(Config.get_agent(agent_name)) ->
        send_message(chat_id, gettext("There's no agent to set the model on."))

      true ->
        agent = Config.get_agent(agent_name)
        Config.put_agent(%{agent | model: name})
        send_message(chat_id, gettext("Model set to %{name}.", name: name))
    end
  end

  defp tools_text do
    body =
      Cortex.Tools.all()
      |> Enum.map(fn mod -> {mod.name(), tool_label(mod)} end)
      |> Enum.sort()
      |> Enum.map_join("\n\n", fn {name, desc} -> "• " <> htmlb(name) <> " — " <> esc(desc) end)

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
  defp tool_summary("config_get"), do: gettext("Read the Cortex configuration.")
  defp tool_summary("config_set"), do: gettext("Change a Cortex setting.")
  defp tool_summary("enable_tool"), do: gettext("Enable a tool for yourself.")
  defp tool_summary("set_route"), do: gettext("Add or remove an agent-to-agent route.")
  defp tool_summary(_other), do: nil

  # Translated one-liners for the built-in skills, shown in the "/" menu and the
  # /skill list (in the configured language). User skills fall back to their own
  # first line (nil here).
  defp skill_summary("install-tool"), do: gettext("How to install a new tool when asked.")

  defp skill_summary("handle-media"),
    do: gettext("Understand a voice/audio/image/file the user sent.")

  defp skill_summary("manage-routing"), do: gettext("Change which agents can message each other.")
  defp skill_summary("skill-creator"), do: gettext("Create, edit, audit or improve a skill.")

  defp skill_summary("write-a-script"),
    do: gettext("Tackle a complex task by writing and running a script.")

  defp skill_summary(_other), do: nil

  # First sentence of a description, trimmed — keeps the tool list scannable.
  defp short_desc(text) do
    first =
      text
      |> String.trim()
      |> String.split(~r/(?<=\.)\s/, parts: 2)
      |> List.first()
      |> to_string()

    if String.length(first) > 110, do: String.slice(first, 0, 109) <> "…", else: first
  end

  defp skills_text do
    case Cortex.Skills.list() do
      [] ->
        gettext("No skills are available yet.")

      skills ->
        htmlb(gettext("Available skills (run with /skill <name>):")) <>
          "\n\n" <>
          Enum.map_join(skills, "\n\n", fn {name, summary} ->
            "• " <> htmlb(name) <> " — " <> esc(skill_summary(name) || summary)
          end)
    end
  end

  # Run a skill by handing the agent an instruction to carry it out; it reads the
  # skill via its `skill` tool and follows the steps (replying in the user's tongue).
  defp run_skill(chat_id, name, args) do
    case Cortex.Skills.read(name) do
      nil ->
        send_message(chat_id, gettext("Unknown skill: %{name}", name: name))

      _content ->
        extra = if args == "", do: "", else: "\n\nInput: #{args}"
        chat_with_agent(chat_id, "Carry out the \"#{name}\" skill now." <> extra)
    end
  end

  # /approve — inspect or clear the agent's persistent ("always allow") grants.
  defp manage_approvals(chat_id, []) do
    agent_name = Config.telegram()["agent"] || Config.default_agent_name()

    case Config.get_agent(agent_name) do
      nil ->
        send_message(chat_id, gettext("No agent is configured."))

      %{auto_approve: []} ->
        send_message(chat_id, gettext("Nothing is pre-approved — I'll ask before risky tools."))

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
    agent_name = Config.telegram()["agent"] || Config.default_agent_name()

    case Config.get_agent(agent_name) do
      nil ->
        send_message(chat_id, gettext("No agent is configured."))

      agent ->
        Config.put_agent(%{agent | auto_approve: fun.(agent)})
        send_message(chat_id, ok_message)
    end
  end

  defp session_key(chat_id), do: "telegram:#{chat_id}"

  defp ensure_session(chat_id) do
    agent = Config.telegram()["agent"] || Config.default_agent_name()
    Cortex.Agent.SessionSupervisor.ensure(session_key(chat_id), agent)
  end

  defp send_message(chat_id, text) do
    # Telegram caps messages at 4096 chars.
    text
    |> chunk(4000)
    |> Enum.each(fn part ->
      Req.post(api_url(token(), "sendMessage"), json: %{chat_id: chat_id, text: part})
    end)
  end

  # Send an HTML-formatted message (bold names, etc.). Callers must escape dynamic
  # text with `esc/1`; `htmlb/1` does both (escape + bold).
  defp send_html(chat_id, text) do
    text
    |> chunk(4000)
    |> Enum.each(fn part ->
      Req.post(api_url(token(), "sendMessage"),
        json: %{chat_id: chat_id, text: part, parse_mode: "HTML"}
      )
    end)
  end

  defp htmlb(text), do: "<b>" <> esc(text) <> "</b>"

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
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

  # The config `enabled` flag — lets you pause the bot without deleting the token.
  defp active?, do: Config.telegram()["enabled"] != false

  # Both the chat and the user must clear their (optional) allowlists. An empty or
  # missing list means "no restriction" on that dimension.
  defp allowed?(chat_id, user_id) do
    tg = Config.telegram()
    allowlisted?(tg["allowed_chats"], chat_id) and allowlisted?(tg["allowed_users"], user_id)
  end

  defp allowlisted?(list, id) when is_list(list) and list != [], do: id in list
  defp allowlisted?(_no_restriction, _id), do: true

  # DMs always reach the agent. In groups, optionally require an @mention (or a
  # /command) so the bot doesn't answer every message.
  defp addressed?(_text, "private"), do: true

  defp addressed?(text, _group) do
    if require_mention?(), do: mentions_bot?(text) or command?(text), else: true
  end

  defp require_mention?, do: Config.telegram()["require_mention"] != false
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
    case :persistent_term.get({__MODULE__, :username}, :unset) do
      :unset ->
        username = fetch_username()
        :persistent_term.put({__MODULE__, :username}, username)
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
