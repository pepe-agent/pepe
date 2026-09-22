defmodule Pepe.Skills.Overrides do
  @moduledoc """
  A user copy of a skill that shadows one Pepe ships.

  A skill in `<PEPE_HOME>/skills/` with the same name as a built-in wins over it. That is how
  an operator adapts a built-in, and also how a stale copy quietly outlives an improvement in
  a new release. Three things make it manageable: knowing which built-ins are overridden,
  seeing exactly what differs, and putting the shipped version back.

  Nothing here deletes anything. `reset/2` archives the user copy (see `Pepe.Skills.Lifecycle`),
  which is recoverable with `mix pepe skill restore NAME`, so the built-in serves again and the
  operator's edits are still there to look at.
  """

  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Lifecycle

  @context 2

  @type override :: %{name: String.t(), user: String.t(), builtin: String.t(), changed?: boolean()}

  @doc "Every built-in skill that a user copy currently shadows."
  @spec list() :: [override()]
  def list do
    for skill <- Catalog.all(), skill.source == :user, %{entry: builtin} <- [builtin_of(skill.name)] do
      %{name: skill.name, user: skill.entry, builtin: builtin, changed?: File.read(skill.entry) != File.read(builtin)}
    end
  end

  @doc """
  What the user copy of `name` changes relative to the built-in, as `{:same | :removed | :added,
  line}` tuples with a couple of lines of context and `{:skipped, count}` for the unchanged
  stretches in between. `{:error, :not_overridden}` when there is no user copy, or nothing built
  in to compare it with.
  """
  @spec diff(String.t()) :: {:ok, [term()]} | {:error, :not_overridden}
  def diff(name) do
    with %{entry: user} <- user_of(name),
         %{entry: builtin} <- builtin_of(name),
         {:ok, a} <- File.read(builtin),
         {:ok, b} <- File.read(user) do
      {:ok, compare(a, b)}
    else
      _ -> {:error, :not_overridden}
    end
  end

  @doc "The diff as text: `-` for what the built-in has and the copy lost, `+` for what the copy added."
  @spec format([term()]) :: String.t()
  def format(diff) do
    Enum.map_join(diff, "\n", fn
      {:same, line} -> "  " <> line
      {:removed, line} -> "- " <> line
      {:added, line} -> "+ " <> line
      {:skipped, count} -> "  ... #{count} unchanged lines"
    end)
  end

  @doc "Put the shipped version back by archiving the user copy. `{:ok, archive_dir}`."
  @spec reset(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_overridden | term()}
  def reset(name, actor) do
    if builtin_of(name) && user_of(name), do: Lifecycle.archive(name, actor), else: {:error, :not_overridden}
  end

  defp user_of(name), do: Enum.find(Catalog.tiers_of(name), &(&1.source == :user))
  defp builtin_of(name), do: Enum.find(Catalog.tiers_of(name), &(&1.source == :builtin))

  defp compare(a, b) do
    a
    |> String.split("\n")
    |> List.myers_difference(String.split(b, "\n"))
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &{:same, &1})
      {:del, lines} -> Enum.map(lines, &{:removed, &1})
      {:ins, lines} -> Enum.map(lines, &{:added, &1})
    end)
    |> trim_context()
  end

  # Keep `@context` unchanged lines on each side of a change and fold the rest.
  defp trim_context(lines) do
    changed = lines |> Enum.with_index() |> Enum.filter(fn {{kind, _}, _} -> kind != :same end) |> Enum.map(&elem(&1, 1))

    if changed == [] do
      []
    else
      keep = changed |> Enum.flat_map(&Enum.to_list(max(&1 - @context, 0)..(&1 + @context))) |> MapSet.new()

      lines
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_line, index} -> MapSet.member?(keep, index) end)
      |> Enum.flat_map(&fold_chunk(&1, keep))
    end
  end

  defp fold_chunk([{_line, index} | _] = chunk, keep) do
    if MapSet.member?(keep, index), do: Enum.map(chunk, &elem(&1, 0)), else: [{:skipped, length(chunk)}]
  end
end
