defmodule Pepe.Hooks.LlmRedact do
  @moduledoc """
  Reversible PII redaction using a **local/configured model** (`settings["model"]`).
  Asks the model to replace PII with realistic pseudonyms and return a `fake -> real`
  map, so the main agent sees only pseudonyms and the reply reads naturally; the
  pipeline restores the real values on the way out. Reuses the session's existing
  pseudonyms so a name stays consistent across turns.

  Best paired with `pii_redact` (regex handles structured ids deterministically;
  the model handles names/addresses/free text in any language). Fail-open: if the
  model is missing or errors, the original text passes through (pair with a model
  `require_redaction` trava when you need a hard guarantee).
  """
  @behaviour Pepe.Hooks.Hook

  require Logger

  alias Pepe.Config
  alias Pepe.LLM.Message

  @impl true
  def stages, do: [:inbound, :tool_result]

  @impl true
  def run(stage, text, settings, ctx) when stage in [:inbound, :tool_result] do
    with name when is_binary(name) <- settings["model"],
         model when not is_nil(model) <- Config.get_model(name),
         {:ok, %{content: content} = result} when is_binary(content) <-
           Pepe.LLM.chat(model, prompt(text, ctx["map"] || []), []),
         {:ok, redacted, entries} <- parse(content) do
      meter(ctx["agent"], model, result[:usage])
      {:ok, redacted, entries}
    else
      failure ->
        log_fail_open(failure, settings)
        {:ok, text}
    end
  end

  def run(_stage, text, _settings, _ctx), do: {:ok, text}

  # Fail-open never leaks the raw text into logs (that's the PII this hook exists to
  # protect) - only the reason, so an operator can tell "silently passed through
  # unredacted" from "working as intended" instead of it being invisible.
  defp log_fail_open(failure, settings) do
    Logger.warning("[llm_redact] failing open (#{fail_reason(failure, settings)}) - text passed through unredacted")
  end

  defp fail_reason(nil, settings) do
    case Map.get(settings, "model") do
      name when is_binary(name) -> "unknown model connection #{inspect(name)}"
      _ -> "no model configured"
    end
  end

  defp fail_reason({:error, reason}, _settings), do: "model call failed: #{inspect(reason)}"
  defp fail_reason({:ok, _}, _settings), do: "model returned a non-text response"
  defp fail_reason(:error, _settings), do: "could not parse the model's redaction response as JSON"
  defp fail_reason(_other, _settings), do: "unexpected failure"

  # Runs on every inbound/tool-result message once enabled - a real, recurring model
  # call that must not silently vanish from spend just because it isn't the main turn.
  defp meter(agent_name, model, usage) when is_binary(agent_name) and is_map(usage),
    do: Pepe.Usage.record(agent_name, model, usage)

  defp meter(_agent_name, _model, _usage), do: :ok

  @impl true
  def config_schema do
    [
      %{"field" => "model", "type" => "model", "required" => true},
      %{"field" => "reversible", "type" => "bool", "default" => true}
    ]
  end

  defp prompt(text, existing) do
    reuse =
      if existing == [],
        do: "",
        else:
          "Reuse these existing pseudonyms for the same real values:\n" <>
            Enum.map_join(existing, "\n", fn e -> "  #{e["real"]} -> #{e["fake"]}" end) <> "\n\n"

    system = """
    You are a PII pseudonymizer. Rewrite the user's message replacing every piece of
    personal data (names, addresses, documents, phones, emails, account numbers, ...)
    with a REALISTIC fake of the same kind, so the text still reads naturally. Keep
    everything else identical. Be consistent: the same real value always maps to the
    same fake.

    #{reuse}Reply with ONLY a JSON object, no prose:
    {"redacted": "<the rewritten text>", "map": [{"fake": "<fake>", "real": "<real>", "type": "<kind>"}]}
    """

    [Message.system(system), Message.user(text)]
  end

  defp parse(content) do
    content
    |> String.trim()
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{"redacted" => redacted} = m} when is_binary(redacted) ->
        {:ok, redacted, sanitize(m["map"])}

      _ ->
        :error
    end
  end

  defp sanitize(list) when is_list(list) do
    for %{"fake" => f, "real" => r} = e <- list, is_binary(f), f != "" do
      %{"fake" => f, "real" => to_string(r), "type" => e["type"] || "pii"}
    end
  end

  defp sanitize(_), do: []

  defp strip_fences(s) do
    s
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end
end
