defmodule Pepe.Tools.ManageChannel do
  @moduledoc """
  Let an agent create and manage **Telegram channels (bots)** from a conversation -
  "add a bot for the sales agent", "point the ops bot at a different agent".

  Deliberately guarded, so autonomy stays safe:

    * **In the agent's tool allowlist** - that's the on/off; and it's a risky tool, so
      each call goes through the permission gate unless pre-approved.
    * **Scoped to named bots** - it only touches bots under `"telegrams"`, never the
      protected `"default"` bot or any other config. (The equivalent of an allowlist
      of editable config paths.)
    * **Secrets never pass through the chat** - you give the *name of an environment
      variable* that holds the token, not the token itself. It's stored as
      `${THE_VAR}` and resolved at read time, so the raw secret never reaches the
      model or the logs.

  After any change it asks the gateway supervisor to reconcile the running pollers,
  so the bot starts/stops live (no restart) when the server is up.

  Actions: `add`, `list`, `set_agent`, `enable`, `disable`, `remove`.

  On a connection with `agent_switch_locked` set, `bind_topic` and `unbind_topic` are
  refused outright (see `run/2`) - and, unlike `switch_agent` on the same connection,
  this tool stays fully visible to the model rather than being hidden: its other actions
  (`list`, `set_trainers`, ...) have nothing to do with the lock. Only those two action
  names are missing from the `action` parameter's own `enum` for a locked turn (see
  `Pepe.Agent.Runtime.run_chain/3`'s `strip_bind_topic_actions/1`), so the model can't
  even construct a call the API's schema would accept for either of them.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Project
  alias Pepe.SeenChannels

  # A conventional environment-variable name (so a raw token, which contains ":",
  # is rejected - the agent must reference an env var instead).
  @env_var ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def name, do: "manage_channel"

  @impl true
  def spec do
    function(
      "manage_channel",
      """
      Create and manage Telegram bots (channels), each bound to an agent. A bot is a \
      whole channel that talks to one agent. IMPORTANT: never pass a raw bot token - \
      pass `token_env`, the NAME of an environment variable that holds the token \
      (e.g. "SALES_BOT_TOKEN"); the secret stays out of this chat. Confirm the details \
      with the user first.

      actions:
      - add: needs `name` (the bot's label, not "default"), `token_env` (env var name \
        with the @BotFather token), `agent` (an existing agent this bot talks to).
      - list: show configured bots (name, agent, whether active).
      - set_agent: rebind a bot to another agent - needs `name`, `agent`.
      - bind_topic: channel administration, not a conversation hand-off. Permanently routes \
        every future message in the CURRENT conversation (a Telegram chat or forum topic, a \
        Slack/Discord/Teams/Google Chat channel, a DM - whatever this conversation is) to \
        `agent`, persistent, surviving /new and restarts. Only for an operator configuring \
        routing ahead of time. NOT for a user asking to talk to, be connected with, or \
        transferred to another agent right now; that's switch_agent (or the /agent command), \
        never this. Needs `agent`. Refused outright on a channel where agent switching is \
        locked. It binds the conversation YOU are in right now, never another channel: to \
        route a DIFFERENT channel (e.g. a Slack channel you are not talking in) use \
        bind_channel.
      - list_channels: the webhook connections (Slack, Discord, ...) and the channels each has \
        heard from - connection slug, channel id, name, and which agent it is routed to. Run \
        this first to get the slug and id for bind_channel; never guess them.
      - bind_channel: permanently route one specific channel of a webhook connection (Slack, \
        Discord, Teams, Google Chat, WhatsApp) to `agent`, from anywhere. Needs `connection` \
        (the connection's slug, e.g. "A0C5LM7LHS8"), `channel` (the channel id, e.g. \
        "C0CD1EG9MFC", or its name as listed, e.g. "sec-radar") and `agent`. The routing key is built for you, so NEVER hand-edit \
        `channel_agents` / `channel_mentions` in config.json and never guess a key. The \
        result prints the exact key it wrote. No restart needed.
      - unbind_channel: undo bind_channel - needs `connection` and `channel`.
      - unbind_topic: remove this conversation's agent binding (back to the channel's own \
        default agent).
      - set_trainers: who the bot LEARNS from - needs `name`, `trainers` ("*" = \
        everyone, "none" = nobody (client-facing bot), or comma-separated user ids).
      - set_heartbeat: enable/tune the bot's proactive heartbeat - needs `name`; \
        `heartbeat_minutes` (integer, how often to check; omit/0 disables it) and \
        optional `heartbeat_hours` ("8-22", quiet outside that local-hour window).
      - set_progress: how the bot signals "I'm working" while running - needs `name` \
        and `mode`: "reaction" (default - a 👀 reaction on the user's message, no text), \
        "ambient" (one vague activity line), "off" (just the typing indicator), or \
        "verbose" (a per-tool breadcrumb list).
      - enable / disable / remove: needs `name`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" =>
              ~w(add list set_agent set_trainers set_heartbeat set_progress bind_topic unbind_topic list_channels bind_channel unbind_channel enable disable remove),
            "description" => "What to do."
          },
          "mode" => %{
            "type" => "string",
            "enum" => ~w(reaction ambient off verbose),
            "description" => "For set_progress: how much working activity to show."
          },
          "name" => %{"type" => "string", "description" => "The bot's name (never \"default\")."},
          "token_env" => %{
            "type" => "string",
            "description" => "NAME of the env var holding the bot token, e.g. \"SALES_BOT_TOKEN\". Never the token itself."
          },
          "agent" => %{"type" => "string", "description" => "Existing agent to bind the bot to."},
          "connection" => %{
            "type" => "string",
            "description" => "For bind_channel/unbind_channel: the webhook connection's slug."
          },
          "channel" => %{
            "type" => "string",
            "description" => "For bind_channel/unbind_channel: the channel id on that connection (e.g. Slack \"C0123ABC\")."
          },
          "trainers" => %{
            "type" => "string",
            "description" => "Who the bot learns from: \"*\", \"none\", or \"id1,id2\"."
          },
          "heartbeat_minutes" => %{
            "type" => "integer",
            "description" => "How often (minutes) to check in proactively. 0 disables it."
          },
          "heartbeat_hours" => %{
            "type" => "string",
            "description" => "Local-hour active window, e.g. \"8-22\" (omit = always active)."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    cond do
      is_nil(ctx[:agent]) ->
        {:error, "no calling agent in context"}

      # A channel-wide policy, not a per-agent one - refused regardless of the calling
      # agent's own tool allowlist. See the comment on Pepe.Agent.Runtime.run_chain/3's
      # own ctx field for how this gets here.
      action in ["bind_topic", "unbind_topic"] and ctx[:agent_switch_locked] == true ->
        {:error, "agent switching is locked on this channel"}

      # These act on the *current* forum topic, so they need the conversation's session key.
      action == "bind_topic" ->
        bind_topic(args, ctx)

      action == "unbind_topic" ->
        unbind_topic(ctx)

      action in ~w(list_channels bind_channel unbind_channel) ->
        channel_action(action, args, ctx)

      true ->
        dispatch(action, args)
    end
  end

  def run(_args, _ctx), do: {:error, "manage_channel needs an `action`"}

  # Bind this conversation to `agent`, so from now on it is answered by it (persistent -
  # survives /new and restarts). The user asks in plain language ("connect this channel to
  # the engineer") and the agent does it; no /agent command to remember. Works the same for
  # any surface - the session key already uniquely identifies the conversation - so this
  # never needs to know it's talking to Telegram, Slack, or anything else.
  defp bind_topic(args, ctx) do
    with {:ok, agent} <- fetch(args, "agent"),
         qualified = Project.qualify(agent, ctx.agent.name),
         :ok <- ensure_same_scope(qualified, ctx.agent.name),
         :ok <- ensure_agent(qualified),
         {:ok, key} <- session_key(ctx) do
      Config.bind_channel_agent(key, qualified)

      {:ok,
       "This conversation (#{key}) is now bound to agent #{qualified} - it will answer here from now on, kept across /new and restarts. " <>
         "Only THIS conversation changed; to route another channel use bind_channel."}
    end
  end

  # Route one specific channel of a webhook connection, from any conversation. The agent only
  # names the connection and the channel; the session key (which embeds the provider and the
  # connection's own default agent, `"slack:default/CarenOps:C1"`) is built here by the same
  # function the inbound path uses, so it can never drift from what the router later looks up.
  defp channel_action("list_channels", _args, ctx), do: list_channels(ctx)
  defp channel_action("bind_channel", args, ctx), do: bind_channel(args, ctx)
  defp channel_action("unbind_channel", args, ctx), do: unbind_channel(args, ctx)

  defp bind_channel(args, ctx) do
    with {:ok, agent} <- fetch(args, "agent"),
         qualified = Project.qualify(agent, ctx.agent.name),
         :ok <- ensure_same_scope(qualified, ctx.agent.name),
         :ok <- ensure_agent(qualified),
         {:ok, key} <- channel_key(args, ctx) do
      Config.bind_channel_agent(key, qualified)

      {:ok,
       "Channel #{args["channel"]} of connection #{args["connection"]} is now routed to #{qualified} (key #{key}), kept across /new and restarts."}
    end
  end

  defp unbind_channel(args, ctx) do
    with {:ok, key} <- channel_key(args, ctx) do
      Config.bind_channel_agent(key, nil)
      {:ok, "Channel #{args["channel"]} of connection #{args["connection"]} is no longer routed to a specific agent (key #{key})."}
    end
  end

  defp channel_key(args, ctx) do
    with {:ok, slug} <- fetch(args, "connection"),
         {:ok, channel} <- fetch(args, "channel"),
         entry when is_map(entry) <- Config.get_webhook(slug) || {:error, "no webhook connection \"#{slug}\""},
         :ok <- ensure_same_scope(entry["agent"] || "", ctx.agent.name),
         :ok <- ensure_unlocked(entry) do
      {:ok, Pepe.Webhooks.session_key(entry, resolve_channel(slug, channel))}
    end
  end

  # The id when it was given, else a channel heard from under that name ("#sec-radar" or
  # "sec-radar"); anything else is taken as an id not heard from yet.
  defp resolve_channel(slug, given) do
    wanted = given |> String.trim_leading("#") |> String.downcase()
    seen = SeenChannels.list(slug)

    case Enum.find(seen, &(&1.channel == given)) || Enum.find(seen, &named?(&1, wanted)) do
      nil -> given
      channel -> channel.channel
    end
  end

  defp named?(channel, wanted), do: Enum.any?([channel.name, channel.label], &(is_binary(&1) and String.downcase(&1) == wanted))

  # Only the connections of the caller's own project, so a listing never shows another tenant's.
  defp list_channels(ctx) do
    rows =
      for {slug, entry} <- Config.webhooks(),
          Project.same_scope?(entry["agent"] || "", ctx.agent.name),
          channel <- SeenChannels.list(slug) do
        bound = Config.channel_agent(Pepe.Webhooks.session_key(entry, channel.channel)) || "(connection default #{entry["agent"]})"
        "- #{slug} (#{entry["provider"]}) channel #{channel.channel} #{channel.label || channel.name || ""}: #{bound}"
      end

    case rows do
      [] ->
        {:ok,
         "No webhook channel heard from yet. A channel shows up here after its first message; its id can still be passed to bind_channel."}

      rows ->
        {:ok, Enum.join(rows, "\n")}
    end
  end

  defp ensure_unlocked(%{"agent_switch_locked" => true}), do: {:error, "agent switching is locked on that connection"}
  defp ensure_unlocked(_entry), do: :ok

  # A bare name resolves inside the calling agent's own project, same as switch_agent; an
  # explicitly cross-project handle ("other/agent") is refused outright, so this can't durably
  # bind a channel to a different tenant's agent.
  defp ensure_same_scope(qualified, from_name) do
    if Project.same_scope?(qualified, from_name), do: :ok, else: {:error, "#{qualified} belongs to a different project"}
  end

  defp unbind_topic(ctx) do
    with {:ok, key} <- session_key(ctx) do
      Config.bind_channel_agent(key, nil)
      {:ok, "This conversation is no longer bound to a specific agent - it falls back to the channel's own default agent."}
    end
  end

  # Nothing reads a binding written under these prefixes - the dashboard, an embedded widget,
  # the OpenAI-compatible API and the ACP editor adapter each have their own throwaway or
  # per-request session, not a durable channel anyone comes back to. Only Telegram
  # (`Pepe.Gateways.Telegram.topic_agent/0`) and the shared webhook gateway
  # (`Pepe.Webhooks.apply_channel_binding/3`) ever look one up, so refuse the rest outright
  # instead of writing a config entry nothing will ever act on.
  @no_channel_to_bind ~w(web: widget: api: acp:)

  defp session_key(ctx) do
    case ctx[:session_key] do
      key when is_binary(key) and key != "" ->
        if Enum.any?(@no_channel_to_bind, &String.starts_with?(key, &1)) do
          {:error,
           "this conversation has no channel to bind - that only works on Telegram, Slack, Discord, MS Teams, Google Chat or WhatsApp"}
        else
          {:ok, key}
        end

      _ ->
        {:error, "no conversation to bind: this only works inside a real conversation"}
    end
  end

  defp dispatch("list", _args), do: {:ok, render_list(Config.telegram_bots())}
  defp dispatch("add", args), do: add(args)
  defp dispatch("set_agent", args), do: set_agent(args)
  defp dispatch("set_trainers", args), do: set_trainers(args)
  defp dispatch("set_heartbeat", args), do: set_heartbeat(args)
  defp dispatch("set_progress", args), do: set_progress(args)
  defp dispatch("enable", args), do: toggle(args, true)
  defp dispatch("disable", args), do: toggle(args, false)
  defp dispatch("remove", args), do: remove(args)
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  defp add(args) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, token_env} <- fetch(args, "token_env"),
         :ok <- validate_env(token_env),
         {:ok, agent} <- fetch(args, "agent"),
         :ok <- ensure_agent(agent) do
      Config.put_telegram_bot(name, %{"bot_token" => "${#{token_env}}", "agent" => agent})
      reload()

      {:ok,
       "Bot #{name} created -> agent #{agent}, token from $#{token_env}. " <>
         token_note(token_env)}
    end
  end

  defp set_agent(args) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, agent} <- fetch(args, "agent"),
         :ok <- ensure_agent(agent),
         {:ok, bot} <- fetch_bot(name) do
      Config.put_telegram_bot(name, Map.put(bot, "agent", agent))
      reload()
      {:ok, "Bot #{name} now talks to agent #{agent}."}
    end
  end

  defp set_trainers(args) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, raw} <- fetch(args, "trainers"),
         {:ok, bot} <- fetch_bot(name) do
      trainers =
        case String.trim(raw) do
          "*" -> ["*"]
          "none" -> []
          csv -> csv |> String.split(",") |> Enum.flat_map(&parse_id/1)
        end

      Config.put_telegram_bot(name, Map.put(bot, "trainers", trainers))
      reload()
      {:ok, "Bot #{name} now learns from: #{trainers_text(trainers)}."}
    end
  end

  defp parse_id(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> [n]
      :error -> []
    end
  end

  defp trainers_text(["*"]), do: "everyone"
  defp trainers_text([]), do: "no one"
  defp trainers_text(list), do: Enum.join(list, ", ")

  defp set_heartbeat(args) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, bot} <- fetch_bot(name) do
      minutes = args["heartbeat_minutes"]

      bot =
        case minutes do
          n when is_integer(n) and n > 0 -> Map.put(bot, "heartbeat_minutes", n)
          _ -> Map.delete(bot, "heartbeat_minutes")
        end

      bot =
        case parse_hours(args["heartbeat_hours"]) do
          {:ok, window} -> Map.put(bot, "heartbeat_active_hours", window)
          :skip -> bot
          :clear -> Map.delete(bot, "heartbeat_active_hours")
        end

      Config.put_telegram_bot(name, bot)
      reload()

      state =
        if bot["heartbeat_minutes"], do: "every #{bot["heartbeat_minutes"]}min", else: "disabled"

      {:ok, "Bot #{name} heartbeat: #{state}."}
    end
  end

  defp set_progress(args) do
    with {:ok, name} <- fetch(args, "name"),
         {:ok, mode} <- fetch(args, "mode"),
         :ok <- validate_progress(mode),
         {:ok, bot} <- fetch_bot(name) do
      save_bot(name, Map.put(bot, "tool_progress", mode))
      reload()
      {:ok, "Bot #{name} activity display: #{mode}."}
    end
  end

  defp validate_progress(m) when m in ~w(reaction ambient off verbose), do: :ok
  defp validate_progress(_), do: {:error, "mode must be reaction, ambient, off or verbose"}

  # The default bot lives in the "telegram" map; named bots in "telegrams".
  defp save_bot("default", bot), do: Config.put_telegram(Map.delete(bot, "name"))
  defp save_bot(name, bot), do: Config.put_telegram_bot(name, bot)

  defp parse_hours(nil), do: :skip
  defp parse_hours(""), do: :clear

  defp parse_hours(str) do
    case String.split(str, "-") do
      [a, b] ->
        with {start, ""} <- Integer.parse(String.trim(a)),
             {finish, ""} <- Integer.parse(String.trim(b)) do
          {:ok, [start, finish]}
        else
          _ -> :skip
        end

      _ ->
        :skip
    end
  end

  defp toggle(args, enabled?) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, bot} <- fetch_bot(name) do
      Config.put_telegram_bot(name, Map.put(bot, "enabled", enabled?))
      reload()
      {:ok, "Bot #{name} #{if enabled?, do: "enabled", else: "disabled"}."}
    end
  end

  defp remove(args) do
    with {:ok, name} <- fetch(args, "name"),
         :ok <- guard_name(name),
         {:ok, _bot} <- fetch_bot(name) do
      Config.delete_telegram_bot(name)
      reload()
      {:ok, "Bot #{name} removed."}
    end
  end

  ###
  ### guards & helpers
  ###

  # Never let the agent touch the protected default bot.
  defp guard_name("default"), do: {:error, "the \"default\" bot is protected; use another name"}
  defp guard_name(_name), do: :ok

  defp validate_env(token_env) do
    if Regex.match?(@env_var, token_env) do
      :ok
    else
      {:error,
       "`token_env` must be an environment-variable NAME (e.g. SALES_BOT_TOKEN), not a raw token. " <>
         "Ask the user to set that env var to the token; the secret must not go through the chat."}
    end
  end

  defp ensure_agent(agent) do
    if Config.get_agent(agent), do: :ok, else: {:error, "unknown agent: #{agent}"}
  end

  # A named bot must already exist for set_agent/enable/disable/remove.
  defp fetch_bot(name) do
    case Config.telegram_bot(name) do
      nil -> {:error, "no bot named #{name}"}
      bot -> {:ok, Map.delete(bot, "name")}
    end
  end

  defp reload do
    Pepe.Gateways.Supervisor.reload_telegram()
  rescue
    _ -> :ok
  end

  defp token_note(token_env) do
    if System.get_env(token_env) do
      "The env var is set, so it can start now."
    else
      "Note: $#{token_env} isn't set in this environment yet - set it (and restart the gateway) for the bot to run."
    end
  end

  defp render_list([]), do: "No Telegram bots configured."

  defp render_list(bots) do
    Enum.map_join(bots, "\n", fn b ->
      active = if Pepe.Gateways.Telegram.bot_active?(b), do: "active", else: "inactive"
      "• #{b["name"]} -> agent #{b["agent"] || "(default)"} [#{active}]"
    end)
  end

  defp fetch(args, key) do
    case blank_to_nil(args[key]) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(v), do: v
end
