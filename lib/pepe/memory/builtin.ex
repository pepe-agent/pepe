defmodule Pepe.Memory.Builtin do
  @moduledoc """
  The default occupant of the `memory` slot: a lexical match over the blank-line-separated
  entries `Pepe.Learning` splits `MEMORY.md`/`USER.md`/`people.md` (and any other knowledge
  `.md` the agent keeps) into - no embeddings API, no vector store.

  The query is split into words and compared with case and accents folded, and entries are
  ranked by how many of the words they contain. Matching the query as one literal phrase
  made a natural question ("banco de dados dos leads") find nothing in a note that said
  "Postgres dos leads", and `acao` never matched `ação`: the note existed and the search
  said it did not.

  Memory files are kept small by design (the reflect/consolidate loop exists specifically
  to stop them from growing), so a corpus this size has little for embeddings to catch that
  substring matching would miss. A richer backend (vector, hybrid) is a plugin occupying
  this slot instead - see `Pepe.Memory.Backend`.
  """

  @behaviour Pepe.Memory.Backend

  alias Pepe.Agent.Workspace
  alias Pepe.Learning
  alias Pepe.Memory.Hit

  @impl true
  def name, do: "builtin"

  @impl true
  def slot, do: "memory"

  @impl true
  def capabilities, do: %{keyword: true, vector: false}

  @impl true
  def search(agent_name, query, opts) do
    limit = Keyword.get(opts, :limit, 20)
    terms = terms(query)
    dir = Workspace.dir(agent_name)

    hits =
      files(agent_name)
      |> Enum.flat_map(&file_hits(dir, &1, terms))
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(limit)

    {:ok, hits}
  end

  # The three memory files first, then whatever other knowledge notes the agent keeps (a
  # `databases.md`, a `clients.md`): a fact filed there is still the agent's memory.
  defp files(agent_name) do
    memory = Learning.memory_files()
    memory ++ (Workspace.knowledge_files(agent_name) -- memory) ++ daily_logs(agent_name)
  end

  # The agent's daily logs (`memory/YYYY-MM-DD.md`), newest first and capped, so a year of them is
  # not read on every search.
  @daily_logs_searched 60

  defp daily_logs(agent_name) do
    case File.ls(Path.join(Workspace.dir(agent_name), "memory")) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort(:desc)
        |> Enum.take(@daily_logs_searched)
        |> Enum.map(&Path.join("memory", &1))

      _ ->
        []
    end
  end

  defp file_hits(_dir, _file, []), do: []

  defp file_hits(dir, file, terms) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} ->
        # Half the words must match: a long question still drags in common words ("the",
        # "with"), and one of those alone is not a reason to return an unrelated note.
        needed = max(1, div(length(terms), 2))

        for entry <- Learning.entries(content),
            score = score(fold(entry), terms),
            score >= needed do
          {score, %Hit{file: file, entry: entry, source: "builtin"}}
        end

      _ ->
        []
    end
  end

  defp score(folded, terms), do: Enum.count(terms, &String.contains?(folded, &1))

  # Words of three letters or more, so "de"/"do"/"a" don't match everything; a query made only
  # of short words (an id, "AI") keeps them rather than searching for nothing.
  defp terms(query) do
    words = query |> fold() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true) |> Enum.uniq()

    case Enum.filter(words, &(String.length(&1) >= 3)) do
      [] -> words
      long -> long
    end
  end

  defp fold(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end
end
