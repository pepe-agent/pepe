defmodule Pepe.Tools.MemorySearch do
  @moduledoc """
  Search an agent's own memory (`MEMORY.md`, `USER.md`, `people.md`) instead of reading a
  whole file to find one thing. A thin wrapper over `Pepe.Memory.search/3`, which runs
  whatever currently occupies the `memory` slot (see `Pepe.Slots`) - the builtin lexical
  search by default, or an installed backend the operator configured instead.

  Read-only and self-scoped (an agent's own memory only), so it's always-safe.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "memory_search"

  @impl true
  def spec do
    function(
      "memory_search",
      """
      Search your own memory (MEMORY.md, USER.md, people.md) for entries mentioning \
      `query` (case-insensitive substring), instead of reading a whole file to find \
      one thing. Returns each match with which file it came from.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Substring to search for."},
          "limit" => %{"type" => "integer", "description" => "Caps how many results come back (default 20)."}
        },
        "required" => ["query"]
      }
    )
  end

  @impl true
  def run(%{"query" => query} = args, ctx) when is_binary(query) and query != "" do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> search(agent, query, args["limit"])
    end
  end

  def run(_args, _ctx), do: {:error, "memory_search needs a `query`"}

  defp search(agent, query, limit) do
    case Pepe.Memory.search(agent.name, query, [limit: limit || 20], agent) do
      {:ok, []} -> {:ok, "No matches for #{inspect(query)}."}
      {:ok, hits} -> {:ok, format(hits, agent)}
      {:error, reason} -> {:error, "memory search failed: #{inspect(reason)}"}
    end
  end

  defp format(hits, agent) do
    text = Enum.map_join(hits, "\n\n", &"[#{&1.file}] #{&1.entry}")

    # The builtin only ever reads the agent's own MEMORY.md/USER.md/people.md - trusted,
    # like the rest of its own workspace. A plugin occupying the memory slot instead could
    # be backed by anything (a remote vector store, someone else's data) - content from
    # outside the conversation, same class fetch_url/web_search results already get. Scoped
    # to THIS agent - a per-agent slot override means one agent's plugin-backed answer and
    # another's builtin one must not share a single global trust verdict.
    if Pepe.Slots.plugin_answering?("memory", agent) do
      text
      |> Pepe.Security.ExternalContent.sanitize()
      |> then(&Pepe.Security.ExternalContent.mark_untrusted("memory_search", &1))
    else
      text
    end
  end
end
