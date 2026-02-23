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

  alias Pepe.Config
  alias Pepe.LLM.Message

  @impl true
  def stages, do: [:inbound]

  @impl true
  def run(:inbound, text, settings, ctx) do
    with name when is_binary(name) <- settings["model"],
         model when not is_nil(model) <- Config.get_model(name),
         {:ok, %{content: content}} when is_binary(content) <-
           Pepe.LLM.chat(model, prompt(text, ctx["map"] || []), []),
         {:ok, redacted, entries} <- parse(content) do
      {:ok, redacted, entries}
    else
      _ -> {:ok, text}
    end
  end

  def run(_stage, text, _settings, _ctx), do: {:ok, text}

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
