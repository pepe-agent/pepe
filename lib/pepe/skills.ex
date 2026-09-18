defmodule Pepe.Skills do
  @moduledoc """
  Skills are on-demand instruction docs (Markdown) that teach the agent a
  *procedure* - e.g. how to install a tool. Built-in skills ship under
  `priv/skills/`; user skills live in `<PEPE_HOME>/skills/` and override a
  built-in of the same name.

  They are NOT loaded into the system prompt in full - only their name + a one-line
  summary are listed there. The agent reads the relevant one with the `skill` tool
  when its topic comes up, keeping context lean.

  A skill is either a loose `<name>.md` file (the common case), or a **package**: a
  `<name>/` directory holding its entry doc (`SKILL.md`, or `<name>.md`, or its first
  `*.md`) plus whatever else it ships alongside, e.g. `scripts/`. A bundled script is
  never copied anywhere on install - it's reached in place, the same way a plugin file
  or the shared workspace already are, via the `skills/<name>/...` path
  `Pepe.Agent.Workspace.resolve/2` understands (so `run_script`'s own `file` argument,
  which resolves through the exact same function, can point straight at it).

  ## Portable metadata header

  An entry doc may open with a YAML metadata header (`---` fenced), the interchange
  form the wider agent-skill ecosystem publishes in:

      ---
      name: read-pdf
      description: Extract text and tables from PDFs. Use when the user sends a PDF.
      ---

      Step one...

  When a header is present its `description` is the skill's summary, and the body below
  it is the instructions. Without one, nothing changes: the **first non-empty line** is
  the summary, as it always was. Both shapes are first-class, so a skill written for any
  compatible tool drops into `<PEPE_HOME>/skills/` and works, and a skill written here
  is readable by them. Unknown header keys (`license`, `metadata`, `compatibility`, ...)
  are preserved verbatim in the doc and otherwise ignored, which is what the interchange
  format asks of a reader.
  """

  alias Pepe.Config

  # A `description` is a purpose-written trigger: the "what it does" half runs first and
  # the "when to use it" half - the half that decides whether the agent opens the skill at
  # all - runs last, so cutting it as short as a prose opening line would defeat it. The
  # cap is still well under the interchange format's own 1024, so one verbose skill cannot
  # crowd out the rest of the index.
  @description_limit 500
  @first_line_limit 120

  @doc "User skills directory."
  def user_dir, do: Path.join(Config.home(), "skills")

  defp builtin_dir, do: Application.app_dir(:pepe, "priv/skills")

  @doc "All skills as `[{name, summary}]` (user skills override built-ins by name)."
  def list do
    (skills_in(builtin_dir()) ++ skills_in(user_dir()))
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Read a skill's full Markdown by name (user dir wins over built-in)."
  def read(name) do
    case read_from(user_dir(), name) do
      {:error, :not_found} -> read_from(builtin_dir(), name)
      result -> result
    end
  end

  @doc """
  The entry doc inside a skill package directory: `SKILL.md` if present, else
  `<dirname>.md`, else its first `*.md` - `nil` if none match. Public so
  `Pepe.Skills.Marketplace` can find the same file when re-scanning an already-installed
  package (`audit/1`) that install-time staging used to decide it was a package.
  """
  @spec package_entry(String.t()) :: String.t() | nil
  def package_entry(dir) do
    skill_md = Path.join(dir, "SKILL.md")
    named = Path.join(dir, Path.basename(dir) <> ".md")

    cond do
      File.regular?(skill_md) -> skill_md
      File.regular?(named) -> named
      true -> Path.wildcard(Path.join(dir, "*.md")) |> List.first()
    end
  end

  @doc """
  Split a skill doc into its YAML metadata header and the body below it, as
  `{metadata, body}`.

  `{%{}, content}` when there is no header at all, and also when what looks like one does
  not parse as a YAML map: a doc that merely opens with a horizontal rule is still just a
  doc, and is returned byte-for-byte rather than half-eaten.
  """
  @spec header(String.t()) :: {map(), String.t()}
  def header("---\n" <> rest = content), do: split_header(rest, content)
  def header("---\r\n" <> rest = content), do: split_header(rest, content)
  def header(content) when is_binary(content), do: {%{}, content}

  defp split_header(rest, original) do
    case Regex.split(~r/^---[ \t]*\r?$/m, rest, parts: 2) do
      [yaml, body] -> parse_header(yaml, body, original)
      _ -> {%{}, original}
    end
  end

  defp parse_header(yaml, body, original) do
    case yaml_map(yaml) do
      {:ok, map} -> {map, body |> String.replace_prefix("\r\n", "") |> String.replace_prefix("\n", "")}
      :error -> {%{}, original}
    end
  end

  # The YAML parser raises (rather than returning an error tuple) on some malformed
  # input, and a third-party skill's header is exactly the place to expect malformed
  # input - a bad header must degrade to "no header", never take down the skills index.
  defp yaml_map(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp read_from(dir, name) do
    loose = Path.join(dir, name <> ".md")
    package = Path.join(dir, name)

    cond do
      File.regular?(loose) -> File.read(loose)
      File.dir?(package) -> read_package(package)
      true -> {:error, :not_found}
    end
  end

  defp read_package(dir) do
    case package_entry(dir) do
      nil -> {:error, :not_found}
      file -> File.read(file)
    end
  end

  defp skills_in(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &skill_entry(dir, &1))
      _ -> []
    end
  end

  defp skill_entry(dir, entry) do
    full = Path.join(dir, entry)

    cond do
      String.ends_with?(entry, ".md") and File.regular?(full) ->
        [{String.replace_suffix(entry, ".md", ""), summary(full)}]

      File.dir?(full) ->
        case package_entry(full) do
          nil -> []
          doc -> [{entry, summary(doc)}]
        end

      true ->
        []
    end
  end

  # A metadata header's `description` is the skill's "use-when" summary; without one, the
  # first non-empty line of the body is.
  defp summary(path) do
    case File.read(path) do
      {:ok, content} -> summarize(content)
      _ -> ""
    end
  end

  defp summarize(content) do
    {meta, body} = header(content)

    case meta["description"] do
      description when is_binary(description) -> one_line(description, @description_limit)
      _ -> first_line(body)
    end
  end

  # A bare `---` is never a summary in either shape - it is a horizontal rule, or the fence
  # of a header that did not parse. Skipping it is what keeps an unreadable header from
  # putting the literal fence in the skills index, where it tells the agent nothing at all
  # about when to open the skill.
  defp first_line(body) do
    case body |> String.split("\n") |> Enum.find(&(String.trim(&1) not in ["", "---"])) do
      nil -> ""
      line -> line |> String.replace_prefix("# ", "") |> one_line(@first_line_limit)
    end
  end

  # The index is one line per skill, and YAML folded/literal scalars carry real newlines -
  # left in, a single description would break the listing into bogus entries.
  defp one_line(text, limit), do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, limit)
end
