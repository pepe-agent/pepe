defmodule Cortex.Tools.ConfigSet do
  @moduledoc """
  Change a Cortex setting from chat — **fail-closed** config self-management.

  Only settings on the explicit allowlist below are editable; anything else is
  refused (secrets, tool allowlists, bot tokens and agent definitions have their own
  guarded tools — `manage_agent`, `manage_channel`, `manage_mcp`). Every value is
  validated before it's written. Calling with no `setting` returns the schema —
  the editable settings, their current values and what's accepted — so the agent
  can discover what's possible instead of guessing.
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Config

  @locales ~w(en pt_BR pt_PT es)

  @impl true
  def name, do: "config_set"

  @impl true
  def spec do
    function(
      "config_set",
      "Change a Cortex setting. Call with no arguments first to see the editable settings (the schema), their current values and accepted values. Only allowlisted settings can be changed — secrets and structural config go through their own tools (manage_agent, manage_channel, manage_mcp).",
      %{
        "type" => "object",
        "properties" => %{
          "setting" => %{
            "type" => "string",
            "description" => "Which setting (omit to list the schema)."
          },
          "value" => %{"type" => "string", "description" => "The new value."}
        }
      }
    )
  end

  # The editable-settings allowlist: {setting, description, validate+write}.
  # Fail-closed: a setting not in this list cannot be changed from chat.
  defp schema do
    [
      {"default_model", "an existing model connection name", &set_default_model/1},
      {"default_agent", "an existing agent name", &set_default_agent/1},
      {"language", "system-message language: #{Enum.join(@locales, " | ")}", &set_language/1},
      {"timezone", "default IANA timezone for scheduled tasks (e.g. America/Sao_Paulo)",
       &set_timezone/1},
      {"telegram.require_mention", "true|false — in groups, reply only when @mentioned",
       &set_tg_flag("require_mention", &1)},
      {"telegram.enabled", "true|false — pause/resume the default bot without deleting it",
       &set_tg_flag("enabled", &1)}
    ]
  end

  @impl true
  def run(%{"setting" => setting, "value" => value}, _ctx)
      when is_binary(setting) and is_binary(value) do
    case List.keyfind(schema(), setting, 0) do
      {^setting, _desc, write} ->
        write.(value)

      nil ->
        {:error,
         "setting #{setting} is not editable from chat (fail-closed). Editable: " <>
           Enum.map_join(schema(), ", ", &elem(&1, 0)) <>
           ". Agents/bots/MCP have their own tools."}
    end
  end

  def run(_args, _ctx), do: {:ok, render_schema()}

  ###
  ### setters (each validates, then writes)
  ###

  defp set_default_model(value) do
    if Config.get_model(value) do
      Config.set_default_model(value)
      {:ok, "default model → #{value}"}
    else
      {:error, "no model connection named #{value}"}
    end
  end

  defp set_default_agent(value) do
    if Config.get_agent(value) do
      Config.set_default_agent(value)
      {:ok, "default agent → #{value}"}
    else
      {:error, "no agent named #{value}"}
    end
  end

  defp set_language(value) do
    if value in @locales do
      Config.set_locale(value)
      {:ok, "language → #{value}"}
    else
      {:error, "unsupported language #{value} (use one of: #{Enum.join(@locales, ", ")})"}
    end
  end

  defp set_timezone(value) do
    case DateTime.now(value) do
      {:ok, _} ->
        Config.set_default_timezone(value)
        {:ok, "timezone → #{value}"}

      _ ->
        {:error, "unknown IANA timezone: #{value}"}
    end
  end

  defp set_tg_flag(flag, value) when value in ["true", "false"] do
    Config.put_telegram(Map.put(Config.telegram(), flag, value == "true"))
    {:ok, "telegram.#{flag} → #{value}"}
  end

  defp set_tg_flag(flag, _value), do: {:error, "telegram.#{flag} must be true or false"}

  ###
  ### schema rendering (self-discovery)
  ###

  defp render_schema do
    "Editable settings (setting — accepted values — current):\n" <>
      Enum.map_join(schema(), "\n", fn {name, desc, _} ->
        "• #{name} — #{desc} — current: #{current(name)}"
      end) <>
      "\n\nNot editable here: secrets/tokens (${ENV} refs, set by the user), agent " <>
      "definitions (manage_agent), bots (manage_channel), MCP servers (manage_mcp), " <>
      "scheduled tasks (schedule_task)."
  end

  defp current("default_model"), do: Config.default_model_name() || "(none)"
  defp current("default_agent"), do: Config.default_agent_name() || "(none)"
  defp current("language"), do: Config.locale()
  defp current("timezone"), do: Config.default_timezone()

  defp current("telegram.require_mention"),
    do: to_string(Config.telegram()["require_mention"] != false)

  defp current("telegram.enabled"), do: to_string(Config.telegram()["enabled"] != false)
  defp current(_), do: "?"
end
