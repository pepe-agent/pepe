defmodule Cortex.Tools.ManageChannel do
  @moduledoc """
  Let an agent create and manage **Telegram channels (bots)** from a conversation —
  "add a bot for the sales agent", "point the ops bot at a different agent".

  Deliberately guarded, so autonomy stays safe:

    * **In the agent's tool allowlist** — that's the on/off; and it's a risky tool, so
      each call goes through the permission gate unless pre-approved.
    * **Scoped to named bots** — it only touches bots under `"telegrams"`, never the
      protected `"default"` bot or any other config. (The equivalent of an allowlist
      of editable config paths.)
    * **Secrets never pass through the chat** — you give the *name of an environment
      variable* that holds the token, not the token itself. It's stored as
      `${THE_VAR}` and resolved at read time, so the raw secret never reaches the
      model or the logs.

  After any change it asks the gateway supervisor to reconcile the running pollers,
  so the bot starts/stops live (no restart) when the server is up.

  Actions: `add`, `list`, `set_agent`, `enable`, `disable`, `remove`.
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Config

  # A conventional environment-variable name (so a raw token, which contains ":",
  # is rejected — the agent must reference an env var instead).
  @env_var ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def name, do: "manage_channel"

  @impl true
  def spec do
    function(
      "manage_channel",
      """
      Create and manage Telegram bots (channels), each bound to an agent. A bot is a \
      whole channel that talks to one agent. IMPORTANT: never pass a raw bot token — \
      pass `token_env`, the NAME of an environment variable that holds the token \
      (e.g. "SALES_BOT_TOKEN"); the secret stays out of this chat. Confirm the details \
      with the user first.

      actions:
      - add: needs `name` (the bot's label, not "default"), `token_env` (env var name \
        with the @BotFather token), `agent` (an existing agent this bot talks to).
      - list: show configured bots (name, agent, whether active).
      - set_agent: rebind a bot to another agent — needs `name`, `agent`.
      - set_trainers: who the bot LEARNS from — needs `name`, `trainers` ("*" = \
        everyone, "none" = nobody (client-facing bot), or comma-separated user ids).
      - set_heartbeat: enable/tune the bot's proactive heartbeat — needs `name`; \
        `heartbeat_minutes` (integer, how often to check; omit/0 disables it) and \
        optional `heartbeat_hours` ("8-22", quiet outside that local-hour window).
      - set_progress: how the bot signals "I'm working" while running — needs `name` \
        and `mode`: "reaction" (default — a 👀 reaction on the user's message, no text), \
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
              ~w(add list set_agent set_trainers set_heartbeat set_progress enable disable remove),
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
            "description" =>
              "NAME of the env var holding the bot token, e.g. \"SALES_BOT_TOKEN\". Never the token itself."
          },
          "agent" => %{"type" => "string", "description" => "Existing agent to bind the bot to."},
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
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_channel needs an `action`"}

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
       "Bot #{name} created → agent #{agent}, token from $#{token_env}. " <> token_note(token_env)}
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
    Cortex.Gateways.Supervisor.reload_telegram()
  rescue
    _ -> :ok
  end

  defp token_note(token_env) do
    if System.get_env(token_env) do
      "The env var is set, so it can start now."
    else
      "Note: $#{token_env} isn't set in this environment yet — set it (and restart the gateway) for the bot to run."
    end
  end

  defp render_list([]), do: "No Telegram bots configured."

  defp render_list(bots) do
    Enum.map_join(bots, "\n", fn b ->
      active = if Cortex.Gateways.Telegram.bot_active?(b), do: "active", else: "inactive"
      "• #{b["name"]} → agent #{b["agent"] || "(default)"} [#{active}]"
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
