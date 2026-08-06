defmodule Pepe.Memory.Builtin do
  @moduledoc """
  The default occupant of the `memory` slot: a plain case-insensitive substring match over
  the same blank-line-separated entries `Pepe.Learning` already splits `MEMORY.md`/
  `USER.md`/`people.md` into for the TimeLearn timeline - no embeddings API, no vector
  store, matching `session_search`'s own search over traces.

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
    needle = String.downcase(query)
    dir = Workspace.dir(agent_name)

    hits =
      Learning.memory_files()
      |> Enum.flat_map(&file_hits(dir, &1, needle))
      |> Enum.take(limit)

    {:ok, hits}
  end

  defp file_hits(dir, file, needle) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} ->
        content
        |> Learning.entries()
        |> Enum.filter(&String.contains?(String.downcase(&1), needle))
        |> Enum.map(&%Hit{file: file, entry: &1, source: "builtin"})

      _ ->
        []
    end
  end
end
