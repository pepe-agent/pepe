defmodule Pepe.Tools.RenameAgent do
  @moduledoc "Let the agent rename itself (config entry + workspace directory)."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace
  alias Pepe.Config

  @impl true
  def name, do: "rename_agent"

  @impl true
  def spec do
    function(
      "rename_agent",
      "Rename yourself (this agent) to a new handle: this renames your config entry and moves your workspace directory to the new name. Use it when the user wants you to be known under a different name. Your persona/identity itself lives in SOUL.md/IDENTITY.md — this only changes the handle/directory.",
      %{
        "type" => "object",
        "properties" => %{
          "new_name" => %{"type" => "string", "description" => "The new agent handle."}
        },
        "required" => ["new_name"]
      }
    )
  end

  @impl true
  def run(%{"new_name" => new_name}, ctx) when is_binary(new_name) and new_name != "" do
    case ctx[:agent] do
      %{name: old} when is_binary(old) and old != new_name ->
        case Config.rename_agent(old, new_name) do
          {:error, :not_found} ->
            {:error, "this agent (#{old}) isn't in the config"}

          _ ->
            Workspace.rename(old, new_name)
            retarget_telegram(old, new_name)
            {:ok, "Renamed to #{new_name}; workspace moved. Takes effect on the next message."}
        end

      %{name: ^new_name} ->
        {:ok, "already named #{new_name}"}

      _ ->
        {:error, "no bound agent to rename"}
    end
  end

  def run(_, _), do: {:error, "missing 'new_name'"}

  # Follow the rename anywhere a Telegram bot is pinned to the old name — the
  # default bot and any named (multi-channel) bots.
  defp retarget_telegram(old, new_name) do
    telegram = Config.telegram()

    if telegram["agent"] == old do
      Config.put_telegram(Map.put(telegram, "agent", new_name))
    end

    for bot <- Config.telegram_bots(), bot["name"] != "default", bot["agent"] == old do
      Config.put_telegram_bot(bot["name"], Map.put(bot, "agent", new_name))
    end
  end
end
