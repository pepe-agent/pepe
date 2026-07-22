defmodule Pepe.Tools.MemorySearch do
  @moduledoc """
  Search an agent's own memory (`MEMORY.md`, `USER.md`, `people.md`) instead of
  reading a whole file to find one thing. Lexical, not semantic: a plain
  case-insensitive substring match over the same blank-line-separated entries
  `Pepe.Learning` already splits these files into for the TimeLearn timeline -
  no embeddings API, no vector store, matching `session_search`'s own search
  over `traces`. Memory files are kept small by design (the reflect/consolidate
  loop exists specifically to stop them from growing), so a corpus this size has
  little for embeddings to catch that substring matching would miss.

  Read-only and self-scoped (an agent's own memory only), so it's always-safe.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace
  alias Pepe.Learning

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
    limit = limit || 20
    needle = String.downcase(query)
    dir = Workspace.dir(agent.name)

    matches =
      Learning.memory_files()
      |> Enum.flat_map(&file_matches(dir, &1, needle))
      |> Enum.take(limit)

    case matches do
      [] -> {:ok, "No matches for #{inspect(query)}."}
      _ -> {:ok, Enum.join(matches, "\n\n")}
    end
  end

  defp file_matches(dir, file, needle) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} ->
        content
        |> Learning.entries()
        |> Enum.filter(&String.contains?(String.downcase(&1), needle))
        |> Enum.map(&"[#{file}] #{&1}")

      _ ->
        []
    end
  end
end
