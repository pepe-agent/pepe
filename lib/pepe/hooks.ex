defmodule Pepe.Hooks do
  @moduledoc """
  The message-flow hook pipeline - the single place surfaces run redaction (and
  other transforms) through. A hook is opt-in: an agent with no `hooks` (and no
  company `default_hooks`) runs raw, exactly as before.

  `transform/4` runs an agent's hooks for a stage, threading the text and collecting
  the reversible map (pseudonym -> real). `restore/2` puts the real values back on the
  way out. Both are applied by `Pepe.Agent.Session`, so every surface (WhatsApp,
  Telegram, API, console) gets it uniformly - like token metering.
  """

  require Logger

  alias Pepe.Company
  alias Pepe.Config

  @providers %{
    "pii_redact" => Pepe.Hooks.PiiRedact,
    "llm_redact" => Pepe.Hooks.LlmRedact,
    "http_redact" => Pepe.Hooks.HttpRedact,
    "presidio" => Pepe.Hooks.Presidio
  }

  @doc "The hook module for a name, or nil."
  def provider(name), do: Map.get(@providers, name)

  @doc "Registered hook names."
  def names, do: Map.keys(@providers)

  @doc """
  Run an agent's `stage` hooks over `text`. Returns `{text, entries}` where `entries`
  are new reversible-map items to remember for `restore/2`. Never raises - a hook
  failure falls back to the current text.
  """
  @spec transform(atom(), String.t(), Pepe.Config.Agent.t() | nil, map()) ::
          {String.t(), [map()]}
  def transform(stage, text, agent, ctx \\ %{}) do
    Enum.reduce(hooks_for(agent), {text, []}, fn {mod, settings}, {txt, entries} ->
      if stage in mod.stages() do
        case safe_run(mod, stage, txt, settings, ctx) do
          {:ok, new_txt} -> {new_txt, entries}
          {:ok, new_txt, new_entries} -> {new_txt, entries ++ new_entries}
        end
      else
        {txt, entries}
      end
    end)
  end

  @doc "Restore real values into `text` from the reversible map (longest token first)."
  @spec restore(String.t(), [map()]) :: String.t()
  def restore(text, []), do: text

  def restore(text, entries) do
    entries
    |> Enum.sort_by(&(-String.length(&1["fake"] || "")))
    |> Enum.reduce(text, fn e, acc ->
      String.replace(acc, e["fake"] || "", to_string(e["real"]))
    end)
  end

  @doc "Does this agent run any hooks at all? (fast path: skip the pipeline if not.)"
  def any?(agent), do: hooks_for(agent) != []

  @doc "The `{module, settings}` list of hooks an agent runs - its own + company defaults."
  def hooks_for(nil), do: []

  def hooks_for(agent) do
    settings = Config.hooks_settings()

    agent
    |> hook_names()
    |> Enum.map(fn name -> {provider(name), Map.get(settings, name, %{})} end)
    |> Enum.reject(fn {mod, _} -> is_nil(mod) end)
  end

  # An agent's own hooks plus any inherited from its company's `default_hooks`.
  defp hook_names(agent) do
    company_defaults =
      case Company.of(agent.name) do
        nil -> []
        co -> (Config.get_company(co) || %{})["default_hooks"] || []
      end

    (company_defaults ++ (agent.hooks || [])) |> Enum.uniq()
  end

  defp safe_run(mod, stage, text, settings, ctx) do
    mod.run(stage, text, settings, ctx)
  rescue
    e ->
      Logger.warning("[hooks] #{inspect(mod)} failed at #{stage}: #{Exception.message(e)}")
      {:ok, text}
  end
end
