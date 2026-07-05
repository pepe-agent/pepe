defmodule Pepe.Tools.TelegramAccess do
  @moduledoc """
  Manage who a Telegram bot is allowed to talk to, by conversation: list the users waiting for
  approval (blocked under `require_approval`), let some in, or dismiss them. The operator can just
  ask their agent ("who's waiting?", "let Salvador and Ana in") instead of opening the dashboard.

  Operator surface: give this tool only to an agent the operator themselves talks to, never a
  customer-facing one - it changes the bot's access list. It reads the target bot from the Telegram
  session it runs in, so it only ever touches the bot the conversation is on.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "telegram_access"

  @impl true
  def spec do
    function(
      "telegram_access",
      "List and manage who this Telegram bot may talk to. Operator-only. `list` shows users waiting " <>
        "for approval; `approve` lets the given user ids in; `dismiss` drops them from the queue " <>
        "(they stay blocked). Get the ids from `list` first.",
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["list", "approve", "dismiss"]},
          "user_ids" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "description" => "For approve/dismiss: the Telegram user ids to act on."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def run(args, ctx) do
    case bot_name(ctx[:session_key]) do
      nil -> {:error, "This tool only works from a Telegram conversation."}
      bot -> handle(bot, args)
    end
  end

  defp handle(bot, %{"action" => "list"}) do
    case Config.telegram_pending(bot) do
      [] ->
        {:ok, "No users are waiting for approval."}

      list ->
        {:ok, "Waiting for approval:\n" <> Enum.map_join(list, "\n", &"- #{&1["name"]} (id #{&1["id"]}): #{&1["sample"]}")}
    end
  end

  defp handle(bot, %{"action" => "approve", "user_ids" => ids}) when is_list(ids) and ids != [] do
    Enum.each(ids, &Config.approve_telegram_user(bot, &1))
    {:ok, "Approved #{length(ids)} user(s); they can talk to the bot now."}
  end

  defp handle(bot, %{"action" => "dismiss", "user_ids" => ids}) when is_list(ids) and ids != [] do
    Enum.each(ids, &Config.dismiss_telegram_pending(bot, &1))
    {:ok, "Dismissed #{length(ids)} user(s) from the queue; they stay blocked."}
  end

  defp handle(_bot, %{"action" => action}) when action in ["approve", "dismiss"] do
    {:error, "'user_ids' (a non-empty list) is required for #{action}."}
  end

  defp handle(_bot, _), do: {:error, "Unknown action. Use list, approve, or dismiss."}

  # The bot a Telegram session belongs to: "telegram:<chat>" is the default bot,
  # "telegram:<name>:<chat>" a named one (a "#t<topic>" suffix on the chat part doesn't matter).
  defp bot_name(key) when is_binary(key) do
    case String.split(key, ":") do
      ["telegram", _chat] -> "default"
      ["telegram", name, _chat] -> name
      _ -> nil
    end
  end

  defp bot_name(_), do: nil
end
