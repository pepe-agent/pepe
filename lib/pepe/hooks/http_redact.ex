defmodule Pepe.Hooks.HttpRedact do
  @moduledoc """
  Custom HTTP redactor: POST the message to your own endpoint, which decides how to
  transform it. The generic escape hatch, so any redaction service (yours, a
  proprietary one) plugs in without a dedicated adapter.

  Request (Pepe -> your endpoint):

      {"stage": "inbound|outbound|tool_result", "text": "...", "session": "...", "map": [...]}

  Response (your endpoint -> Pepe):

      {"text": "transformed text", "map": [{"fake": "...", "real": "...", "type": "..."}]}

  `text` is required; `map` optional (reversible). If it can't process, return the
  original `text`. One `url` (used for every stage) or separate
  `inbound_url`/`outbound_url`/`tool_result_url`. Auth: `basic_auth`
  (`{user, password}`) and/or arbitrary `headers` (name -> value), all
  `${ENV}`-interpolated.
  """
  @behaviour Pepe.Hooks.Hook

  alias Pepe.Config

  @impl true
  def stages, do: [:inbound, :outbound, :tool_result]

  @impl true
  def run(stage, text, settings, ctx) do
    case url_for(stage, settings) do
      url when is_binary(url) and url != "" ->
        body = %{
          "stage" => to_string(stage),
          "text" => text,
          "session" => ctx["session"],
          "map" => ctx["map"] || []
        }

        post(url, body, settings, text)

      _ ->
        {:ok, text}
    end
  end

  @impl true
  def config_schema do
    [
      %{"field" => "url", "type" => "string"},
      %{"field" => "inbound_url", "type" => "string"},
      %{"field" => "outbound_url", "type" => "string"},
      %{"field" => "tool_result_url", "type" => "string"},
      %{"field" => "basic_auth", "type" => "map", "fields" => ["user", "password"]},
      %{"field" => "headers", "type" => "map"}
    ]
  end

  defp post(url, body, settings, fallback) do
    opts =
      [json: body, receive_timeout: 15_000, headers: headers(settings)]
      |> put_auth(settings)

    case Req.post(url, opts) do
      {:ok, %{status: s, body: %{"text" => text} = b}} when s in 200..299 and is_binary(text) ->
        case b["map"] do
          list when is_list(list) -> {:ok, text, sanitize(list)}
          _ -> {:ok, text}
        end

      _ ->
        {:ok, fallback}
    end
  end

  defp url_for(:inbound, s), do: s["inbound_url"] || s["url"]
  defp url_for(:outbound, s), do: s["outbound_url"] || s["url"]
  defp url_for(:tool_result, s), do: s["tool_result_url"] || s["url"]
  defp url_for(_, s), do: s["url"]

  defp headers(settings) do
    for {k, v} <- settings["headers"] || %{}, do: {to_string(k), Config.interpolate(v)}
  end

  defp put_auth(opts, %{"basic_auth" => %{"user" => u, "password" => p}}) when is_binary(u),
    do: Keyword.put(opts, :auth, {:basic, "#{u}:#{Config.interpolate(p)}"})

  defp put_auth(opts, _settings), do: opts

  defp sanitize(list) do
    for %{"fake" => f} = e <- list, is_binary(f), f != "" do
      %{"fake" => f, "real" => to_string(e["real"]), "type" => e["type"] || "pii"}
    end
  end
end
