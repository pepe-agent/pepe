defmodule Pepe.Skills.Lint do
  @moduledoc """
  Advisory checks on a skill's shape, for the standards a reviewer would otherwise catch
  by eye: a trigger a future run can recognise, no marketing adjectives, no incident
  narration, no dangling links, no scaffolding files.

  Findings never block anything by themselves. `Pepe.Tools.SkillManage` attaches them to
  its result so the agent fixes what it just wrote in the same turn, and `pepe skill lint`
  prints them for a person. The *hard* limits (a legal name, a size cap, something to
  summarise) are enforced separately, at write time, by `Pepe.Tools.SkillManage`.
  """

  alias Pepe.Skills

  @type finding :: %{severity: :error | :warning, rule: atom(), message: String.t()}

  @marketing ~w(powerful comprehensive seamless advanced cutting-edge state-of-the-art revolutionary robust)
  @forbidden_files ~w(README.md CHANGELOG.md install.sh .env .env.example .gitignore)
  @max_reference_files 60
  @soft_size 20_000
  @first_line_limit 120
  @description_limit 500

  # A body dense in PR / issue numbers is narrating history instead of stating rules. The
  # threshold is per thousand characters so a long body with one citation is fine.
  @incident_min 4
  @incident_per_kchar 0.5

  @doc """
  Lint the text of a skill's entry doc. Pass `dir:` (the skill's package directory) to also
  check what is on disk beside it, and `name:` to check the header's `name` against it.
  """
  @spec content(String.t(), keyword()) :: [finding()]
  def content(text, opts \\ []) when is_binary(text) do
    {meta, body} = Skills.header(text)

    header_findings(meta, opts[:name]) ++
      summary_findings(meta, body) ++
      body_findings(body, opts[:dir]) ++
      size_findings(text) ++
      file_findings(opts[:dir])
  end

  @doc "Lint the entry doc of the user skill `name` as it is on disk right now."
  @spec skill(String.t()) :: {:ok, [finding()]} | {:error, :not_found}
  def skill(name) do
    case Pepe.Skills.Ownership.user_entry(name) do
      nil ->
        {:error, :not_found}

      {kind, path} ->
        doc = if kind == :loose, do: path, else: Skills.package_entry(path)
        dir = if kind == :package, do: path

        case File.read(doc) do
          {:ok, text} -> {:ok, content(text, name: name, dir: dir)}
          _ -> {:error, :not_found}
        end
    end
  end

  @doc "One line per finding, for a tool result or the CLI."
  @spec format([finding()]) :: String.t()
  def format(findings), do: Enum.map_join(findings, "\n", &"- [#{&1.severity}] #{&1.rule}: #{&1.message}")

  @doc "Does the list contain a finding that should stop a write?"
  @spec errors?([finding()]) :: boolean()
  def errors?(findings), do: Enum.any?(findings, &(&1.severity == :error))

  ###
  ### checks
  ###

  defp header_findings(meta, name) do
    declared = meta["name"]

    []
    |> add(
      is_binary(declared) and not Pepe.Skills.Ownership.valid_name?(declared),
      :error,
      :name_format,
      "the header's name '#{declared}' must be lowercase letters, digits, hyphens and underscores, 64 characters at most."
    )
    |> add(
      is_binary(declared) and is_binary(name) and declared != name,
      :error,
      :name_mismatch,
      "the header's name '#{declared}' does not match the skill's name '#{name}'; they must be identical."
    )
  end

  defp summary_findings(meta, body) do
    {summary, source} = summary_of(meta, body)

    []
    |> add(
      summary == "",
      :error,
      :no_summary,
      "the skill has nothing to summarise: the first line of the body (or the header's description) is what the agent sees in its index."
    )
    |> add(
      source == :header and String.length(summary) > @description_limit,
      :warning,
      :description_length,
      "the description is #{String.length(summary)} characters and the skills index cuts it at #{@description_limit}, which drops the part that says when to use it."
    )
    |> add(
      source == :body and String.length(summary) > @first_line_limit,
      :warning,
      :first_line_length,
      "the first line is #{String.length(summary)} characters and the skills index cuts it at #{@first_line_limit}; make it a short trigger."
    )
    |> add(
      summary != "" and not trigger?(summary),
      :warning,
      :no_trigger,
      "the summary should say WHEN to use the skill (\"Use when ...\"): that line is the only thing the agent sees before deciding to open it."
    )
    |> add(
      marketing(summary) != [],
      :warning,
      :marketing,
      "the summary uses marketing words #{inspect(marketing(summary))}; state what the skill does, not adjectives."
    )
  end

  defp body_findings(body, dir) do
    prose = Regex.replace(~r/```.*?```/s, body, "")
    refs = Regex.scan(~r/(?<![\w\/])#\d{3,6}\b|\b(?:PR|issue)\s*#?\d{3,6}\b/i, prose) |> length()

    []
    |> add(
      refs >= @incident_min and refs / max(String.length(prose), 1) * 1000 >= @incident_per_kchar,
      :warning,
      :incident_log,
      "#{refs} PR/issue numbers in the prose: write the general rule and why, and drop the incident - the rule must stand without the story."
    )
    |> Kernel.++(dangling(body, dir))
  end

  defp dangling(_body, nil), do: []

  defp dangling(body, dir) do
    ~r/(?:references|templates|assets|scripts)\/[\w.\/-]+/
    |> Regex.scan(body)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.reject(&(String.contains?(&1, "*") or String.ends_with?(&1, "/")))
    |> Enum.reject(&File.exists?(Path.join(dir, &1)))
    |> Enum.map(&finding(:warning, :dangling_reference, "the body points at '#{&1}' but that file is not in the skill's directory."))
  end

  defp size_findings(text) do
    add(
      [],
      byte_size(text) > @soft_size,
      :warning,
      :long,
      "the skill is #{byte_size(text)} bytes; every read spends that much context. Move rarely-needed depth into references/ and keep the main flow short."
    )
  end

  defp file_findings(nil), do: []

  defp file_findings(dir) do
    forbidden =
      for f <- @forbidden_files, File.exists?(Path.join(dir, f)) do
        finding(:warning, :forbidden_file, "the skill ships '#{f}'; scaffolding and config files are not skill content.")
      end

    refs = Path.join(dir, "references")

    sprawl =
      if File.dir?(refs) do
        count = refs |> Path.join("**/*.md") |> Path.wildcard() |> length()

        add(
          [],
          count > @max_reference_files,
          :warning,
          :references_sprawl,
          "#{count} files under references/: that is a per-session log, not topical depth. Merge same-topic files into one rule set."
        )
      else
        []
      end

    forbidden ++ sprawl
  end

  ###
  ### helpers
  ###

  defp summary_of(%{"description" => d}, _body) when is_binary(d) and d != "", do: {one_line(d), :header}

  defp summary_of(_meta, body) do
    line = body |> String.split("\n") |> Enum.find(&(String.trim(&1) not in ["", "---"])) || ""
    {line |> String.replace_prefix("# ", "") |> one_line(), :body}
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp trigger?(summary), do: Regex.match?(~r/\bwhen\b/i, summary)

  defp marketing(summary) do
    lower = String.downcase(summary)
    Enum.filter(@marketing, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/, lower))
  end

  defp add(list, true, severity, rule, message), do: list ++ [finding(severity, rule, message)]
  defp add(list, _false, _severity, _rule, _message), do: list

  defp finding(severity, rule, message), do: %{severity: severity, rule: rule, message: message}
end
