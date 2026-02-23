defmodule Pepe.Hooks.Presidio do
  @moduledoc """
  Microsoft Presidio redactor over its HTTP services. Runs the Analyzer to detect
  PII, then the Anonymizer to replace it. Self-hosted (two containers) so the data
  stays under your control.

  Settings: `analyzer_url` and `anonymizer_url` (e.g. `http://presidio-analyzer:3000`),
  `language` (default `en`), optional `entities` (which to detect) and
  `score_threshold`. Irreversible by default (the anonymizer replaces PII); pair
  with `pii_redact` for structured ids you want restored.
  """
  @behaviour Pepe.Hooks.Hook

  @impl true
  def stages, do: [:inbound]

  @impl true
  def run(:inbound, text, settings, _ctx) do
    with a when is_binary(a) <- settings["analyzer_url"],
         an when is_binary(an) <- settings["anonymizer_url"],
         {:ok, %{status: 200, body: results}} when is_list(results) <-
           Req.post("#{a}/analyze", json: analyze_body(text, settings), receive_timeout: 15_000),
         {:ok, %{status: 200, body: %{"text" => redacted}}} when is_binary(redacted) <-
           Req.post("#{an}/anonymize",
             json: %{"text" => text, "analyzer_results" => results},
             receive_timeout: 15_000
           ) do
      {:ok, redacted}
    else
      _ -> {:ok, text}
    end
  end

  def run(_stage, text, _settings, _ctx), do: {:ok, text}

  @impl true
  def config_schema do
    [
      %{"field" => "analyzer_url", "type" => "string", "required" => true},
      %{"field" => "anonymizer_url", "type" => "string", "required" => true},
      %{"field" => "language", "type" => "string", "default" => "en"},
      %{"field" => "entities", "type" => "list"},
      %{"field" => "score_threshold", "type" => "float"}
    ]
  end

  defp analyze_body(text, settings) do
    %{"text" => text, "language" => settings["language"] || "en"}
    |> put_if("entities", settings["entities"])
    |> put_if("score_threshold", settings["score_threshold"])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
