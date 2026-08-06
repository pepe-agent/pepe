defmodule Pepe.Tools.WebSearch do
  @moduledoc """
  Web search - whatever currently occupies the `web_search` slot (see `Pepe.Slots`),
  DuckDuckGo's Instant Answer API by default. Returns a compact summary plus related
  topics. The operator can point this at a keyed, production-grade provider instead
  (`mix pepe slot set web_search NAME`) with no change here.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "web_search"

  @impl true
  def spec do
    function(
      "web_search",
      "Search the web for current, real-world information: news, prices, versions, facts that change, anything past what you already know. If the first query comes back thin, rephrase and search again before giving up - don't fall back on memory.",
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "The search query."}
        },
        "required" => ["query"]
      }
    )
  end

  # Waits on a network.
  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"query" => query}, ctx) do
    case Pepe.Search.search(query, [], ctx[:agent]) do
      {:ok, results} ->
        # Results are content from outside the conversation: strip model control tokens and
        # invisible characters, then wrap them in an explicit untrusted-content marker
        # (Pepe.Security.ExternalContent) before they reach the model - the trust boundary
        # stays here, in the tool, no matter which backend occupies the slot.
        sanitized = Pepe.Security.ExternalContent.sanitize(format(results))
        {:ok, Pepe.Security.ExternalContent.mark_untrusted("web_search", sanitized)}

      {:error, reason} ->
        {:error, "search failed: #{inspect(reason)}"}
    end
  end

  def run(_, _), do: {:error, "missing 'query'"}

  defp format([]), do: "No instant answer found."

  defp format(results) do
    Enum.map_join(results, "\n\n", fn r ->
      [r.title, r.snippet, r.url]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
    end)
  end
end
