defmodule Pepe.Hooks.Generator do
  @moduledoc """
  Generate a `pii_redact` config from a plain-language description, using a
  configured model. The model is told the recognizer/pack schema and asked for
  JSON; every result is validated here (unknown packs/recognizers dropped, each
  custom regex compile-checked) so nothing invalid is ever saved. Writing regex is
  hard; this lets a non-technical user describe what to protect instead.
  """

  alias Pepe.Config
  alias Pepe.Hooks.PII.Recognizers
  alias Pepe.LLM.Message

  @doc """
  Turn `description` into a validated `pii_redact` settings map. Returns
  `{:ok, config, dropped}` where `dropped` lists anything the model proposed that
  didn't validate (bad regex, unknown pack), or `{:error, reason}`.
  """
  @spec generate(String.t(), String.t()) ::
          {:ok, map(), [String.t()]} | {:error, term()}
  def generate(description, model_name) do
    with model when not is_nil(model) <- Config.get_model(model_name),
         {:ok, %{content: content}} when is_binary(content) <-
           Pepe.LLM.chat(model, prompt(description), []),
         {:ok, raw} <- decode(content) do
      {:ok, config, dropped} = validate(raw)
      {:ok, config, dropped}
    else
      nil -> {:error, :unknown_model}
      _ -> {:error, :generation_failed}
    end
  end

  defp prompt(description) do
    system = """
    You configure a PII redactor. Choose from these built-in pieces, and only add a
    custom regex for things they don't cover.

    Packs (bundles): #{Enum.join(Map.keys(Recognizers.packs()), ", ")}
    Recognizers: #{Enum.join(Recognizers.builtin_names(), ", ")}

    Reply with ONLY a JSON object, no prose:
    {"packs": ["..."], "recognizers": ["..."], "custom": [{"name": "snake_case", "pattern": "<regex>", "replace": "[LABEL]"}]}

    Prefer packs/recognizers over custom. Custom patterns must be valid regex.
    """

    [Message.system(system), Message.user(description)]
  end

  defp decode(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
    |> Jason.decode()
  end

  # Keep only known packs/recognizers and custom patterns that compile; collect the
  # rest so the caller can show what was ignored.
  defp validate(raw) do
    packs = raw |> list("packs") |> Enum.filter(&Map.has_key?(Recognizers.packs(), &1))
    recs = raw |> list("recognizers") |> Enum.filter(&(&1 in Recognizers.builtin_names()))

    {custom, dropped} =
      raw
      |> list("custom")
      |> Enum.split_with(fn c ->
        is_binary(c["name"]) and Recognizers.valid_pattern?(c["pattern"])
      end)

    config =
      %{}
      |> put_unless_empty("packs", packs)
      |> put_unless_empty("recognizers", recs)
      |> put_unless_empty(
        "custom",
        Enum.map(custom, &Map.take(&1, ["name", "pattern", "replace"]))
      )

    dropped_names =
      (list(raw, "packs") -- packs) ++
        (list(raw, "recognizers") -- recs) ++
        Enum.map(dropped, &"custom:#{&1["name"] || "?"}")

    {:ok, config, dropped_names}
  end

  defp list(map, key), do: (is_map(map) && is_list(map[key]) && map[key]) || []

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
