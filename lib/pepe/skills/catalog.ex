defmodule Pepe.Skills.Catalog do
  @moduledoc """
  Finds every skill and decides which ones a given caller is offered.

  Skills come from up to four tiers, in this order of precedence (a name found in more
  than one tier is served from the first):

    1. **project** - `<repo>/.pepe/skills` and `<repo>/.agents/skills`, only for a trusted
       repository and only when it passes the scan (see `Pepe.Skills.Project`);
    2. **user** - `<PEPE_HOME>/skills`, where installs and hand-written skills go;
    3. **external** - directories the operator pointed at (`skills.external_dirs`),
       read in place and never written to;
    4. **builtin** - what ships in `priv/skills`.

  Inside a tier a skill is a loose `<name>.md`, or a package directory (`SKILL.md` beside
  its `scripts/`, `references/`, ...). User and external tiers may also group packages
  into category directories, to any depth up to four: `skills/devops/deploy/SKILL.md` is
  the skill `deploy` in category `devops`. Two different skills with the same name *inside
  one tier* are a conflict: the listing shows the first, but reading that name refuses
  and says where the candidates are, because silently picking one is how a copied skill
  ends up shadowing the real one.

  What a caller is *offered* (the index in the system prompt, slash commands) is narrower
  than what exists. A skill drops out when it is disabled, when it names another operating
  system, and - for the offer only, never for an explicit read - when it needs a tool the
  agent does not hold, is a fallback for a tool the agent does hold, is meant for other
  channels, or is scoped to an environment (`docker`) that is not this one.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Frontmatter
  alias Pepe.Skills.Project
  alias Pepe.Skills.Settings
  alias Pepe.Skills.Skill

  @max_depth 4
  @skipped_dirs ~w(node_modules __pycache__ venv site-packages)
  @description_limit 500
  @first_line_limit 120
  @head_bytes 16_384

  @type opts :: [cwd: String.t() | nil, channel: String.t() | nil, agent: map() | nil, offer: boolean()]

  # -- discovery ---------------------------------------------------------------------------

  @doc """
  Every skill that exists, one per name, resolved by tier precedence. Not filtered by what
  a caller may be offered - see `visible/1`. Options: `:cwd` (to find project skills).
  """
  @spec all(opts()) :: [Skill.t()]
  def all(opts \\ []) do
    opts |> gather() |> Enum.map(fn {_name, [winner | _]} -> winner end)
  end

  @doc "Names that resolve to more than one different skill inside their winning tier, as `{name, [entry paths]}`."
  @spec conflicts(opts()) :: [{String.t(), [String.t()]}]
  def conflicts(opts \\ []) do
    for {name, [first | _] = group} <- gather(opts),
        peers = Enum.filter(group, &(&1.source == first.source)),
        match?([_, _ | _], peers),
        do: {name, Enum.map(peers, & &1.entry)}
  end

  @doc "Names defined in more than one tier, as `{name, winning_source, [shadowed_sources]}`."
  @spec shadowed(opts()) :: [{String.t(), Skill.source(), [Skill.source()]}]
  def shadowed(opts \\ []) do
    for {name, [first | _] = group} <- gather(opts),
        losers = group |> Enum.map(& &1.source) |> Enum.uniq() |> List.delete(first.source),
        losers != [],
        do: {name, first.source, losers}
  end

  @doc """
  Every copy of the skill called `name`, one per tier that defines it, highest precedence
  first (the first is the one that is served). Empty when nothing has that name.
  """
  @spec tiers_of(String.t(), opts()) :: [Skill.t()]
  def tiers_of(name, opts \\ []) do
    case List.keyfind(gather(opts), name, 0) do
      {_name, group} -> group
      nil -> []
    end
  end

  @doc """
  Look a skill up by name, by `category/name`, or by the `name` in its own header.
  `{:error, {:ambiguous, entries}}` when the name is defined twice inside its tier.
  """
  @spec find(String.t(), opts()) :: {:ok, Skill.t()} | {:error, :not_found | {:ambiguous, [String.t()]}}
  def find(name, opts \\ []) when is_binary(name) do
    name = String.trim(name)
    groups = gather(opts)

    with :error <- by_key(groups, name),
         :error <- by_path(groups, name),
         :error <- by_header_name(groups, name) do
      {:error, :not_found}
    end
  end

  defp by_key(groups, name) do
    case List.keyfind(groups, name, 0) do
      {_name, group} -> resolve(group)
      nil -> :error
    end
  end

  defp by_path(groups, name) do
    if String.contains?(name, "/") do
      groups
      |> Enum.flat_map(fn {_n, group} -> group end)
      |> Enum.filter(&(Skill.path(&1) == name))
      |> case do
        [] -> :error
        matches -> resolve(matches)
      end
    else
      :error
    end
  end

  defp by_header_name(groups, name) do
    groups
    |> Enum.flat_map(fn {_n, [first | _]} -> [first] end)
    |> Enum.filter(&(&1.fields[:name] == name))
    |> case do
      [] -> :error
      matches -> resolve(matches)
    end
  end

  defp resolve([single]), do: {:ok, single}

  defp resolve([first | _] = group) do
    case Enum.filter(group, &(&1.source == first.source)) do
      [_, _ | _] = peers -> {:error, {:ambiguous, Enum.map(peers, & &1.entry)}}
      _single -> {:ok, first}
    end
  end

  # name => [skills], highest-precedence tier first, sorted by name.
  defp gather(opts) do
    opts
    |> tiers()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{source, roots}, _rank} -> Enum.flat_map(roots, &scan_root(&1, source)) end)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, group} -> {name, Enum.sort_by(group, &{tier_rank(&1.source), &1.entry})} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp tier_rank(:project), do: 0
  defp tier_rank(:user), do: 1
  defp tier_rank(:external), do: 2
  defp tier_rank(:builtin), do: 3

  defp tiers(opts) do
    [
      {:project, Project.dirs(opts[:cwd])},
      {:user, [Skills.user_dir()]},
      {:external, Settings.external_dirs()},
      {:builtin, [Skills.builtin_dir()]}
    ]
  end

  defp scan_root(root, source) do
    root
    |> walk(root, 0, source)
    |> then(fn skills -> if source == :project, do: Enum.reject(skills, &Project.quarantined?(&1.dir || &1.entry)), else: skills end)
  end

  defp walk(dir, root, depth, source) do
    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.sort() |> Enum.flat_map(&visit(&1, dir, root, depth, source))
      _ -> []
    end
  end

  defp visit(entry, dir, root, depth, source) do
    full = Path.join(dir, entry)

    cond do
      String.starts_with?(entry, ".") -> []
      depth == 0 and String.ends_with?(entry, ".md") and File.regular?(full) -> [build_loose(full, root, source)]
      File.dir?(full) and entry not in @skipped_dirs -> visit_dir(full, root, depth, source)
      true -> []
    end
  end

  defp visit_dir(dir, root, depth, source) do
    cond do
      File.regular?(Path.join(dir, "SKILL.md")) -> [build_package(dir, root, source)]
      depth >= @max_depth -> []
      nested_skills?(dir) -> walk(dir, root, depth + 1, source)
      depth == 0 and Skills.package_entry(dir) -> [build_package(dir, root, source)]
      true -> []
    end
  end

  # A directory with no SKILL.md is a category when a skill sits below it.
  defp nested_skills?(dir, depth \\ 0) do
    depth < @max_depth and
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.any?(entries, fn entry ->
            full = Path.join(dir, entry)

            not String.starts_with?(entry, ".") and File.dir?(full) and
              (File.regular?(Path.join(full, "SKILL.md")) or nested_skills?(full, depth + 1))
          end)

        _ ->
          false
      end
  end

  defp build_loose(file, root, source) do
    name = Path.basename(file, ".md")
    build(name, file, nil, root, source, :loose)
  end

  defp build_package(dir, root, source) do
    build(Path.basename(dir), Skills.package_entry(dir), dir, root, source, :package)
  end

  defp build(name, entry, dir, root, source, format) do
    %{meta: meta, body: body, yaml: yaml} = entry |> read_head() |> Frontmatter.parse()

    %Skill{
      name: name,
      summary: summarize(meta, body),
      entry: entry,
      dir: dir,
      source: source,
      category: category(dir || entry, root),
      root: root,
      format: format,
      meta: meta,
      fields: Frontmatter.fields(meta),
      yaml: yaml
    }
  end

  defp read_head(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, data} when is_binary(data) -> data
      _ -> ""
    end
  end

  defp category(path, root) do
    case path |> Path.relative_to(root) |> Path.split() |> Enum.drop(-1) do
      [] -> nil
      parts -> Enum.join(parts, "/")
    end
  end

  @doc false
  # A header's `description` is the skill's "use-when" summary; without one, the first
  # non-empty line of the body is. A bare `---` is never a summary (a horizontal rule, or
  # the fence of a header that did not parse).
  @spec summarize(map(), String.t()) :: String.t()
  def summarize(meta, body) do
    case Frontmatter.fields(meta).description do
      description when is_binary(description) -> one_line(description, @description_limit)
      _ -> first_line(body)
    end
  end

  defp first_line(body) do
    case body |> String.split("\n") |> Enum.find(&(String.trim(&1) not in ["", "---"])) do
      nil -> ""
      line -> line |> String.replace_prefix("# ", "") |> one_line(@first_line_limit)
    end
  end

  # The index is one line per skill, and YAML folded/literal scalars carry real newlines.
  defp one_line(text, limit), do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, limit)

  # -- what a caller is offered -----------------------------------------------------------

  @doc """
  The skills a caller may use, after disabling and gating (see the moduledoc). Options:

    * `:channel` - the surface (`"telegram"`, `"web"`, `"tui"`, ...): channel-specific
      disabling and `channels:` gating apply.
    * `:agent` - a map with `:tools`: `requires_tools` / `fallback_for_tools` apply.
    * `:cwd` - where project skills are looked for.
    * `:offer` - `false` for an explicit read: only the hard gates apply (disabled, wrong
      operating system), never the relevance ones.
  """
  @spec visible(opts()) :: [Skill.t()]
  def visible(opts \\ []) do
    disabled = Settings.disabled_on(opts[:channel])
    Enum.filter(all(opts), &(reason(&1, opts, disabled) == nil))
  end

  @typedoc "Why a skill is not offered: the one reason that decided it."
  @type hidden_reason ::
          :disabled
          | :platform
          | :environment
          | :channel
          | {:requires_tools, [String.t()]}
          | {:fallback_for_tools, [String.t()]}

  @doc """
  Why `skill` is not offered to this caller, or `nil` when it is. The same decision
  `visible/1` makes, with the reason kept: a disabled or wrong-platform skill is hidden
  from everyone, and unless `offer: false` the relevance gates (environment, channel and
  tools) apply on top.
  """
  @spec hidden_reason(Skill.t(), opts()) :: hidden_reason() | nil
  def hidden_reason(%Skill{} = skill, opts \\ []), do: reason(skill, opts, Settings.disabled_on(opts[:channel]))

  defp reason(skill, opts, disabled) do
    cond do
      MapSet.member?(disabled, skill.name) -> :disabled
      not platform_ok?(skill) -> :platform
      Keyword.get(opts, :offer, true) -> relevance_reason(skill, opts)
      true -> nil
    end
  end

  @typedoc "One skill, whether it is offered, and whether the machine has what it declares it needs."
  @type status :: %{skill: Skill.t(), hidden: hidden_reason() | nil, readiness: Pepe.Skills.Readiness.t()}

  @doc """
  Every skill that exists with the reason it is hidden (or `nil`) and its readiness, in name
  order. This is what `mix pepe skill list` prints, so an operator asking "where did my skill
  go?" gets the answer instead of an absence. Options as for `visible/1`, plus `:env` and
  `:which` for `Pepe.Skills.Readiness.check/2`.
  """
  @spec status(opts()) :: [status()]
  def status(opts \\ []) do
    disabled = Settings.disabled_on(opts[:channel])
    readiness_opts = Keyword.take(opts, [:env, :which])

    for skill <- all(opts) do
      %{skill: skill, hidden: reason(skill, opts, disabled), readiness: Pepe.Skills.Readiness.check(skill, readiness_opts)}
    end
  end

  @doc """
  `{root, count}` when the repository around `opts[:cwd]` ships skills of its own that are
  not offered because the operator has not trusted it, else `nil`.
  """
  @spec untrusted_project(opts()) :: {String.t(), pos_integer()} | nil
  def untrusted_project(opts \\ []), do: Project.untrusted(opts[:cwd])

  @doc "Whether `name` is switched off for the given channel (`opts[:channel]`)."
  @spec disabled?(String.t(), opts()) :: boolean()
  def disabled?(name, opts \\ []), do: MapSet.member?(Settings.disabled_on(opts[:channel]), name)

  @doc "Whether the skill's `platforms:` allow this operating system (absent means all)."
  @spec platform_ok?(Skill.t()) :: boolean()
  def platform_ok?(%Skill{fields: %{platforms: []}}), do: true
  def platform_ok?(%Skill{fields: %{platforms: platforms}}), do: Enum.any?(platforms, &(os_name(&1) == current_os()))

  defp os_name(value) do
    case String.downcase(value) do
      "macos" -> :darwin
      "darwin" -> :darwin
      "linux" -> :linux
      "windows" -> :windows
      "win32" -> :windows
      other -> other
    end
  end

  defp current_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      {:win32, _} -> :windows
      {_family, name} -> name
    end
  end

  defp relevance_reason(%Skill{fields: fields}, opts) do
    cond do
      not environments_ok?(fields.environments) -> :environment
      not channels_ok?(fields.channels, opts[:channel]) -> :channel
      true -> tools_reason(fields, agent_tools(opts[:agent]))
    end
  end

  defp agent_tools(%{tools: tools}) when is_list(tools), do: tools
  defp agent_tools(_agent), do: nil

  # No agent given: nothing to compare against, so nothing is hidden on tool grounds.
  defp tools_reason(_fields, nil), do: nil

  defp tools_reason(fields, tools) do
    missing = Enum.reject(fields.requires_tools, &(&1 in tools))
    covered = Enum.filter(fields.fallback_for_tools, &(&1 in tools))

    cond do
      missing != [] -> {:requires_tools, missing}
      covered != [] -> {:fallback_for_tools, covered}
      true -> nil
    end
  end

  defp channels_ok?([], _channel), do: true
  defp channels_ok?(_allowed, nil), do: true
  defp channels_ok?(allowed, channel), do: channel in allowed

  # Tags are an OR; a tag this build does not know fails open, since hiding a skill over a
  # tag nobody can evaluate would be worse than offering it.
  defp environments_ok?([]), do: true
  defp environments_ok?(tags), do: Enum.any?(tags, &environment?/1)

  defp environment?(tag) do
    case String.downcase(tag) do
      "docker" -> File.exists?("/.dockerenv") or File.exists?("/run/.containerenv")
      "container" -> File.exists?("/.dockerenv") or File.exists?("/run/.containerenv")
      "ci" -> System.get_env("CI") not in [nil, "", "false", "0"]
      _unknown -> true
    end
  end
end
