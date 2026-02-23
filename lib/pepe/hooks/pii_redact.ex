defmodule Pepe.Hooks.PiiRedact do
  @moduledoc """
  Regex PII redactor - the offline, zero-dependency default. Replaces matched
  structured PII (email, card, CPF/CNPJ, ...) with a stable token (`[CPF_1]`) and,
  when `reversible` (default), records `token -> real` so the pipeline can restore
  it on the way out. See `Pepe.Hooks.PII.Recognizers` for the recognizer library.
  """
  @behaviour Pepe.Hooks.Hook

  alias Pepe.Hooks.PII.Recognizers

  @impl true
  def stages, do: [:inbound]

  @impl true
  def run(:inbound, text, settings, _ctx) do
    reversible = Map.get(settings, "reversible", true)

    {redacted, entries, _counters} =
      settings
      |> Recognizers.resolve()
      |> Enum.reduce({text, [], %{}}, &redact(&1, &2, reversible))

    if reversible, do: {:ok, redacted, Enum.reverse(entries)}, else: {:ok, redacted}
  end

  def run(_stage, text, _settings, _ctx), do: {:ok, text}

  @impl true
  def config_schema do
    [
      %{"field" => "packs", "type" => "multiselect", "options" => Map.keys(Recognizers.packs())},
      %{
        "field" => "recognizers",
        "type" => "multiselect",
        "options" => Recognizers.builtin_names()
      },
      %{"field" => "custom", "type" => "list", "fields" => ["name", "pattern", "replace"]},
      %{"field" => "reversible", "type" => "bool", "default" => true}
    ]
  end

  # Replace every validated match of one recognizer with a numbered token, recording
  # the reversal entry. Repeated values collapse to one token (replace-all).
  defp redact(
         %{regex: regex, label: label, validate: validate, name: name},
         {text, entries, ctr},
         reversible
       ) do
    matches =
      regex
      |> Regex.scan(text)
      |> Enum.map(&hd/1)
      |> Enum.filter(fn m -> is_nil(validate) or validate.(m) end)
      |> Enum.uniq()

    Enum.reduce(matches, {text, entries, ctr}, fn m, {txt, acc, counters} ->
      n = Map.get(counters, label, 0) + 1
      token = "[#{label}_#{n}]"
      entry = %{"fake" => token, "real" => m, "type" => name}

      {
        String.replace(txt, m, token),
        if(reversible, do: [entry | acc], else: acc),
        Map.put(counters, label, n)
      }
    end)
  end
end
