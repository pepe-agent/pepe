defmodule Pepe.Skills.Pack do
  @moduledoc """
  Turns a skill into something that can be handed to someone else: a `.tar.gz` holding one
  directory named for the skill, which is what `mix pepe skill install NAME --source URL`
  (and every other tool that reads the open format) unpacks.

  A tap is a static JSON index of `name => {source, description}`, so publishing to one is
  hosting the archive and adding its entry. This does the part that can be wrong: it refuses
  a skill that fails the specification check or the Sentinel scan (unless told to go on),
  leaves out anything that is not skill content (dotfiles and directories, scaffolding), and
  returns the checksum and the index entry with its `source` left for the person to fill in
  once they know where it will live.
  """

  alias Pepe.Skills.Sentinel
  alias Pepe.Skills.Validate

  @skipped ~w(.git .DS_Store node_modules __pycache__ .env)

  @type built :: %{
          archive: String.t(),
          name: String.t(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          sha256: String.t(),
          entry: %{String.t() => String.t()},
          report: Validate.report()
        }

  @doc """
  Pack `target` (a skill directory, a skill file, or an installed skill's name). Options:
  `:out` (the archive path; default `<name>.tar.gz` in the current directory) and `:force`
  (pack it even though the check found errors or the Sentinel said `:danger`).
  """
  @spec build(String.t(), keyword()) ::
          {:ok, built()} | {:error, :not_found | {:invalid, Validate.report()} | {:unsafe, map()} | term()}
  def build(target, opts \\ []) do
    with {:ok, report} <- Validate.run(target),
         :ok <- gate(report, opts[:force]),
         name = pack_name(report),
         {:ok, files} <- collect(report, name),
         out = Path.expand(opts[:out] || name <> ".tar.gz"),
         :ok <- write_archive(out, files) do
      bytes = File.stat!(out).size

      {:ok,
       %{
         archive: out,
         name: name,
         files: length(files),
         bytes: bytes,
         sha256: out |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
         entry: %{"name" => name, "description" => description(report)},
         report: report
       }}
    end
  end

  defp gate(report, force?) do
    cond do
      force? -> :ok
      not report.valid? -> {:error, {:invalid, report}}
      true -> scan(report)
    end
  end

  defp scan(report) do
    case report.entry |> File.read!() |> Sentinel.scan() do
      %{verdict: :danger} = scan -> {:error, {:unsafe, scan}}
      _ -> :ok
    end
  end

  # The header's name when it has one, else what the file or directory is called.
  defp pack_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp pack_name(%{entry: entry}), do: entry |> Path.dirname() |> Path.basename()

  defp description(%{entry: entry}) do
    {meta, _body} = entry |> File.read!() |> Pepe.Skills.header()
    if is_binary(meta["description"]), do: meta["description"] |> String.replace(~r/\s+/, " ") |> String.trim(), else: ""
  end

  # `[{archive_path, source_path}]`, every file of the skill under a top directory named for it.
  # A loose skill file becomes that directory's SKILL.md.
  defp collect(%{dir: nil, entry: entry}, name), do: {:ok, [{Path.join(name, "SKILL.md"), entry}]}

  defp collect(%{dir: dir}, name) do
    files =
      dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&skipped?(Path.relative_to(&1, dir)))
      |> Enum.map(&{Path.join(name, Path.relative_to(&1, dir)), &1})

    {:ok, files}
  end

  defp skipped?(relative), do: relative |> Path.split() |> Enum.any?(&(&1 in @skipped or String.starts_with?(&1, ".")))

  defp write_archive(out, files) do
    entries = Enum.map(files, fn {inside, source} -> {String.to_charlist(inside), String.to_charlist(source)} end)

    case :erl_tar.create(String.to_charlist(out), entries, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:archive, reason}}
    end
  end
end
