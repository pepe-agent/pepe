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
  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Readiness

  @doc "User skills directory."
  def user_dir, do: Path.join(Config.home(), "skills")

  @doc "Directory containing the skills shipped with Pepe."
  def builtin_dir, do: Application.app_dir(:pepe, "priv/skills")

  @doc "Visible skills as `[{name, summary}]`, resolved through the tiered catalog."
  def list(opts \\ []) do
    opts
    |> Catalog.visible()
    |> Enum.map(&{&1.name, &1.summary})
  end

  @doc """
  Visible skills as `[{name, summary, needs}]`: the same set as `list/1`, with `needs` set to a
  short note (`"needs API_KEY"`) for a skill whose declared requirements this machine lacks, and
  `nil` otherwise. This is what the skills index in the system prompt is built from.
  """
  @spec index(keyword()) :: [{String.t(), String.t(), String.t() | nil}]
  def index(opts \\ []) do
    for skill <- Catalog.visible(opts) do
      {skill.name, skill.summary, skill |> Readiness.check() |> Readiness.note()}
    end
  end

  @doc "Read a visible skill's full Markdown by name, path or declared alias."
  def read(name, opts \\ []) do
    with {:ok, _skill, content} <- fetch(name, opts), do: {:ok, content}
  end

  @doc """
  Like `read/2`, but also returns the skill, so a caller that renders the text (see
  `Pepe.Skills.Render`) does not look it up twice. Only the hard gates apply (disabled, wrong
  operating system): a person asking for a skill by name gets it even if the agent would not
  have been offered it.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Pepe.Skills.Skill.t(), String.t()} | {:error, term()}
  def fetch(name, opts \\ []) do
    with {:ok, skill} <- Catalog.find(name, opts),
         false <- Catalog.disabled?(skill.name, opts) or not Catalog.platform_ok?(skill),
         {:ok, content} <- File.read(skill.entry) do
      {:ok, skill, content}
    else
      true -> {:error, :not_found}
      error -> error
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
end
