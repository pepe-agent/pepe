defmodule Pepe.Skills.Validate do
  @moduledoc """
  Checks a skill against the open agent-skills specification, and against the advisory rules
  in `Pepe.Skills.Lint`, and says what is wrong in a way its author can act on.

  This is the check to run before publishing or sharing a skill, and the report attached to an
  install. It never blocks anything by itself: Pepe reads more than the specification allows
  (a loose `<name>.md`, underscores in a name, a list where a string is specified), and a skill
  that only trips those still works here. Those are reported as warnings, so the author knows
  it will not travel to another tool. What the specification calls required or limited is an
  error.

  What is checked, from the specification:

    * `name`: required, 1 to 64 characters, lowercase letters and digits with single hyphens
      between them (none at either end), and identical to the skill's directory name;
    * `description`: required, 1 to 1024 characters;
    * `license`: a string when present;
    * `compatibility`: 1 to 500 characters when present;
    * `metadata`: a map of string keys to string values when present;
    * `allowed-tools`: a space-separated string when present;
    * the entry doc is `SKILL.md` and opens with a YAML header that parses;
    * the body stays under 500 lines (the specification's own advice).

  A target is a directory holding a skill, a skill file, or the name of a skill Pepe already
  knows.
  """

  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Frontmatter
  alias Pepe.Skills.Lint
  alias Pepe.Skills.Ownership

  @name_format ~r/^[\p{Ll}\p{Nd}]+(-[\p{Ll}\p{Nd}]+)*$/u
  @max_name 64
  @max_description 1024
  @max_compatibility 500
  @max_body_lines 500

  @type report :: %{
          target: String.t(),
          entry: String.t(),
          dir: String.t() | nil,
          name: String.t() | nil,
          findings: [Lint.finding()],
          errors: non_neg_integer(),
          warnings: non_neg_integer(),
          valid?: boolean()
        }

  @doc """
  Validate `target`: a path to a skill directory or file, or the name of a skill in the catalog.
  `{:error, :not_found}` when it is neither.
  """
  @spec run(String.t(), keyword()) :: {:ok, report()} | {:error, :not_found}
  def run(target, opts \\ []) when is_binary(target) do
    case locate(target, opts) do
      {:ok, entry, dir, expected_name} -> {:ok, report(target, entry, dir, expected_name)}
      :error -> {:error, :not_found}
    end
  end

  @doc "The findings alone, for a text: used where there is no path (a skill being written)."
  @spec findings(String.t(), keyword()) :: [Lint.finding()]
  def findings(text, opts \\ []) when is_binary(text) do
    parsed = Frontmatter.parse(text)
    header_findings(parsed, opts[:expected_name], opts[:entry_name]) ++ body_findings(parsed, text, opts[:dir])
  end

  @doc "One line per finding, or the empty string when there are none."
  @spec format([Lint.finding()]) :: String.t()
  def format(findings), do: Lint.format(findings)

  # -- locating ----------------------------------------------------------------------------

  defp locate(target, opts) do
    cond do
      File.dir?(target) -> from_dir(Path.expand(target))
      File.regular?(target) -> from_file(Path.expand(target))
      true -> from_catalog(target, opts)
    end
  end

  defp from_dir(dir) do
    case Pepe.Skills.package_entry(dir) do
      nil -> :error
      entry -> {:ok, entry, dir, Path.basename(dir)}
    end
  end

  # A `SKILL.md` given by path stands for its directory.
  defp from_file(path) do
    if Path.basename(path) == "SKILL.md",
      do: from_dir(Path.dirname(path)),
      else: {:ok, path, nil, Path.basename(path, ".md")}
  end

  defp from_catalog(name, opts) do
    case Catalog.find(name, Keyword.take(opts, [:cwd, :channel, :agent]) ++ [offer: false]) do
      {:ok, skill} -> {:ok, skill.entry, skill.dir, skill.name}
      _ -> :error
    end
  end

  # -- the report --------------------------------------------------------------------------

  defp report(target, entry, dir, expected_name) do
    text = File.read!(entry)
    parsed = Frontmatter.parse(text)

    findings =
      header_findings(parsed, expected_name, Path.basename(entry)) ++
        body_findings(parsed, text, dir)

    errors = Enum.count(findings, &(&1.severity == :error))

    %{
      target: target,
      entry: entry,
      dir: dir,
      name: parsed.meta |> Map.get("name") |> name_or_nil(),
      findings: findings,
      errors: errors,
      warnings: length(findings) - errors,
      valid?: errors == 0
    }
  end

  defp name_or_nil(name) when is_binary(name), do: name
  defp name_or_nil(_), do: nil

  # -- the header --------------------------------------------------------------------------

  defp header_findings(%{has_header?: false, yaml: :invalid}, _expected, entry) do
    [error(:header_invalid, "the file opens with a --- block that is not a YAML mapping, so it reads as having no header.")] ++
      entry_findings(entry)
  end

  defp header_findings(%{has_header?: false}, _expected, entry) do
    [error(:header_missing, "the specification requires a YAML header (--- fences) with at least a name and a description.")] ++
      entry_findings(entry)
  end

  defp header_findings(%{meta: meta, yaml: yaml}, expected, entry) do
    recovered(yaml) ++
      entry_findings(entry) ++
      name_findings(meta["name"], expected) ++
      description_findings(meta["description"]) ++
      optional_findings(meta)
  end

  defp recovered(:recovered),
    do: [
      warning(
        :header_recovered,
        "a plain value contains ': ' or ' #', which is a YAML error: Pepe read it by quoting the value, other tools may not. Put the value in quotes."
      )
    ]

  defp recovered(_yaml), do: []

  defp entry_findings(nil), do: []
  defp entry_findings("SKILL.md"), do: []

  defp entry_findings(entry),
    do: [
      warning(
        :entry_name,
        "the entry doc is #{entry}; the specification names it SKILL.md, and other tools will not find it under this name."
      )
    ]

  defp name_findings(nil, _expected), do: [error(:name_missing, "the header has no name.")]

  defp name_findings(name, expected) when is_binary(name) do
    cond do
      name == "" ->
        [error(:name_missing, "the header's name is empty.")]

      String.length(name) > @max_name ->
        [error(:name_length, "the name is #{String.length(name)} characters; the limit is #{@max_name}.")]

      Regex.match?(@name_format, name) ->
        mismatch(name, expected)

      underscore_only?(name) ->
        [
          warning(
            :name_portable,
            "the name '#{name}' uses underscores, which Pepe accepts but the specification does not (lowercase letters, digits and single hyphens only); rename it to travel to other tools."
          )
        ] ++ mismatch(name, expected)

      true ->
        [
          error(
            :name_format,
            "the name '#{name}' must be lowercase letters and digits with single hyphens between them, none at either end."
          )
        ]
    end
  end

  defp name_findings(_name, _expected), do: [error(:name_type, "the name must be a string.")]

  # The one deviation Pepe tolerates: the name is exactly what the specification asks for once
  # its underscores are hyphens. Anything else (a trailing hyphen, a space) is an error.
  defp underscore_only?(name),
    do: String.contains?(name, "_") and Ownership.valid_name?(name) and Regex.match?(@name_format, String.replace(name, "_", "-"))

  defp mismatch(_name, nil), do: []
  defp mismatch(name, name), do: []

  defp mismatch(name, expected),
    do: [error(:name_mismatch, "the header's name '#{name}' must be identical to the skill's directory name '#{expected}'.")]

  defp description_findings(description) when is_binary(description) do
    length = description |> String.trim() |> String.length()

    cond do
      length == 0 ->
        [error(:description_missing, "the description is empty; say what the skill does and when to use it.")]

      length > @max_description ->
        [error(:description_length, "the description is #{length} characters; the limit is #{@max_description}.")]

      true ->
        []
    end
  end

  defp description_findings(nil),
    do: [error(:description_missing, "the header has no description; say what the skill does and when to use it.")]

  defp description_findings(_other), do: [error(:description_type, "the description must be a string.")]

  defp optional_findings(meta) do
    license(meta["license"]) ++
      compatibility(meta["compatibility"]) ++
      metadata(meta["metadata"]) ++
      allowed_tools(meta["allowed-tools"])
  end

  defp license(nil), do: []
  defp license(value) when is_binary(value), do: []
  defp license(_value), do: [error(:license_type, "license must be a string: a license name, or the name of a bundled license file.")]

  defp compatibility(nil), do: []

  defp compatibility(value) when is_binary(value) do
    length = String.length(value)

    if length in 1..@max_compatibility//1,
      do: [],
      else: [error(:compatibility_length, "compatibility is #{length} characters; it must be 1 to #{@max_compatibility}.")]
  end

  defp compatibility(_value), do: [error(:compatibility_type, "compatibility must be a string.")]

  defp metadata(nil), do: []

  defp metadata(%{} = map) do
    bad = for {key, value} <- map, not is_binary(value), do: to_string(key)

    if bad == [],
      do: [],
      else: [
        warning(
          :metadata_values,
          "metadata values must be strings; quote #{Enum.join(bad, ", ")} (a bare 1.0 or true reads as a number or boolean)."
        )
      ]
  end

  defp metadata(_value), do: [error(:metadata_type, "metadata must be a mapping of string keys to string values.")]

  defp allowed_tools(nil), do: []
  defp allowed_tools(value) when is_binary(value), do: []

  defp allowed_tools(value) when is_list(value),
    do: [
      warning(
        :allowed_tools_list,
        "allowed-tools is a space-separated string in the specification; Pepe reads a list too, other tools may not."
      )
    ]

  defp allowed_tools(_value), do: [error(:allowed_tools_type, "allowed-tools must be a space-separated string.")]

  # -- the body ----------------------------------------------------------------------------

  defp body_findings(parsed, text, dir) do
    lines = parsed.body |> String.split("\n") |> length()

    long =
      if lines > @max_body_lines,
        do: [
          warning(
            :body_long,
            "the body is #{lines} lines; the specification recommends under #{@max_body_lines}. Move detail into references/ files that are read on demand."
          )
        ],
        else: []

    long ++ Enum.reject(Lint.content(text, dir: dir), &(&1.rule == :name_format))
  end

  defp error(rule, message), do: %{severity: :error, rule: rule, message: message}
  defp warning(rule, message), do: %{severity: :warning, rule: rule, message: message}
end
