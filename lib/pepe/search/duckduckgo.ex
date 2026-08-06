defmodule Pepe.Search.DuckDuckGo do
  @moduledoc """
  The default occupant of the `web_search` slot: DuckDuckGo's Instant Answer API (no key
  required). Good enough for quick lookups; the operator can point `web_search` at a keyed
  provider instead (`mix pepe slot set web_search NAME`) without any tool/model-facing
  change - see `Pepe.Search.Backend`.
  """

  @behaviour Pepe.Search.Backend

  alias Pepe.Search.Result

  @impl true
  def name, do: "duckduckgo"

  @impl true
  def slot, do: "web_search"

  @impl true
  def search(query, _opts) do
    params = [q: query, format: "json", no_html: 1, skip_disambig: 1]

    case Req.get("https://api.duckduckgo.com/", params: params, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, results(body)}
      {:ok, %{status: status}} -> {:error, "search returned status #{status}"}
      {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
    end
  end

  defp results(body) do
    abstract = body["AbstractText"] || body["Answer"] || ""
    abstract_result = if abstract != "", do: [%Result{title: "Summary", url: body["AbstractURL"], snippet: abstract}], else: []

    related =
      (body["RelatedTopics"] || [])
      |> Enum.flat_map(fn
        %{"Text" => text} = topic when is_binary(text) and text != "" -> [%Result{url: topic["FirstURL"], snippet: text}]
        _ -> []
      end)
      |> Enum.take(8)

    abstract_result ++ related
  end
end
