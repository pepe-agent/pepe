defmodule Cortex.Tools.ConfigSet do
  @moduledoc "Change a Cortex setting from chat — the safe, validated config pointers."
  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Config

  @settings ~w(default_model default_agent language)
  @locales ~w(en pt_BR pt_PT es)

  @impl true
  def name, do: "config_set"

  @impl true
  def spec do
    function(
      "config_set",
      "Change a Cortex setting from chat. `setting` is one of: default_model (value = an existing model connection name), default_agent (value = an existing agent name), language (value = en | pt_BR | pt_PT | es — the language of fixed system messages, not your replies).",
      %{
        "type" => "object",
        "properties" => %{
          "setting" => %{
            "type" => "string",
            "enum" => @settings,
            "description" => "What to change."
          },
          "value" => %{"type" => "string", "description" => "The new value."}
        },
        "required" => ["setting", "value"]
      }
    )
  end

  @impl true
  def run(%{"setting" => "default_model", "value" => value}, _ctx) do
    if Config.get_model(value) do
      Config.set_default_model(value)
      {:ok, "default model → #{value}"}
    else
      {:error, "no model connection named #{value}"}
    end
  end

  def run(%{"setting" => "default_agent", "value" => value}, _ctx) do
    if Config.get_agent(value) do
      Config.set_default_agent(value)
      {:ok, "default agent → #{value}"}
    else
      {:error, "no agent named #{value}"}
    end
  end

  def run(%{"setting" => "language", "value" => value}, _ctx) do
    if value in @locales do
      Config.set_locale(value)
      {:ok, "language → #{value}"}
    else
      {:error, "unsupported language #{value} (use one of: #{Enum.join(@locales, ", ")})"}
    end
  end

  def run(_args, _ctx),
    do: {:error, "unknown setting (use default_model, default_agent or language)"}
end
