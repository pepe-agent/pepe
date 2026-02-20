defmodule Pepe.Tools.ConfigGet do
  @moduledoc "Read the current Pepe configuration (so the agent can answer about it / decide changes)."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "config_get"

  @impl true
  def spec do
    function(
      "config_get",
      "Read the current Pepe configuration — model connections, agents, the default model/agent, the system-message language, and Telegram status. Use it to answer the user about the setup or before changing something.",
      %{"type" => "object", "properties" => %{}, "required" => []}
    )
  end

  @impl true
  def run(_args, _ctx) do
    models = Config.models() |> Enum.map(& &1.name)
    agents = Config.agents() |> Enum.map(& &1.name)
    telegram = Config.telegram()
    bots = Config.telegram_bots() |> Enum.map(& &1["name"])
    mcp = Config.mcp_servers() |> Map.keys()
    crons = Config.crons() |> Enum.map(& &1.id)

    text = """
    Models: #{join(models)} (default: #{Config.default_model_name() || "none"})
    Agents: #{join(agents)} (default: #{Config.default_agent_name() || "none"})
    Language: #{Config.locale()} · Timezone: #{Config.default_timezone()}
    Telegram: #{telegram_status(telegram)}
    Bots: #{join(bots)}
    MCP servers: #{join(mcp)}
    Scheduled tasks: #{join(crons)}
    """

    {:ok, String.trim(text)}
  end

  defp join([]), do: "(none)"
  defp join(list), do: Enum.join(list, ", ")

  defp telegram_status(%{"bot_token" => token} = tg) when token not in [nil, ""] do
    extras =
      [
        unless(tg["allowed_users"] in [nil, []],
          do: "allowed_users: #{inspect(tg["allowed_users"])}"
        ),
        unless(tg["allowed_chats"] in [nil, []],
          do: "allowed_chats: #{inspect(tg["allowed_chats"])}"
        ),
        "require_mention: #{tg["require_mention"] != false}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "configured (#{extras})"
  end

  defp telegram_status(_), do: "not configured"
end
