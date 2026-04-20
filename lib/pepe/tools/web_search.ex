defmodule Pepe.Tools.WebSearch do
  @moduledoc """
  Web search via the DuckDuckGo Instant Answer API (no key required). Returns a
  compact summary plus related topics. Good enough for quick lookups; swap the
  endpoint for a keyed provider for production-grade results.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "web_search"

  @impl true
  def spec do
    function("web_search", "Search the web for current information about a query.", %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "The search query."}
      },
      "required" => ["query"]
    })
  end

  @impl true
  def run(%{"query" => query}, _ctx) do
    params = [q: query, format: "json", no_html: 1, skip_disambig: 1]

    case Req.get("https://api.duckduckgo.com/", params: params, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, format(body)}

      {:ok, %{status: status}} ->
        {:error, "search returned status #{status}"}

      {:error, reason} ->
        {:error, "search failed: #{inspect(reason)}"}
    end
  end

  def run(_, _), do: {:error, "missing 'query'"}

  defp format(body) do
    abstract = body["AbstractText"] || body["Answer"] || ""

    related =
      (body["RelatedTopics"] || [])
      |> Enum.flat_map(fn
        %{"Text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.take(8)
      |> Enum.map_join("\n", &("- " <> &1))

    [abstract, related]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> case do
      "" -> "No instant answer found."
      text -> text
    end
  end
end
