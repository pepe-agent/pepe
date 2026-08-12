defmodule Pepe.Skills.Marketplace do
  @moduledoc """
  Install/search/update skills from registries: a bundled default (shipped in-repo, curated,
  currently empty - there is no hosted official registry yet, only the mechanism) plus any
  homebrew-style "taps" the operator adds (`Pepe.Config.skill_taps/0`), not a central service.

  Mirrors `Pepe.Plugins`' install shape (stage -> Sentinel scan -> refuse on `:danger` unless
  `--force` -> place), sharing `Pepe.Sourcing` for the download/stage half.

  A staged source with a `SKILL.md` at its root is a **package**: the whole directory is
  placed (`File.cp_r!`, the same as `Pepe.Plugins`' own `:dir` placement), not just its
  doc, and every other file in it is deep-scanned with `Sentinel.scan_code/2` - the same
  scan a plugin's `.exs` files get - merged with the doc's own `Sentinel.scan/1` into one
  verdict. Anything staged without a `SKILL.md` installs exactly as before: only its
  matching (or first) `*.md` is read and placed, everything else in that directory is
  ignored - a deliberate, explicit trigger, so an ordinary tap/registry checkout that
  happens to hold other files never silently bundles them in.

  **Trust is intrinsic to where a skill resolved from, not self-declared.** A skill resolved
  through the bundled, in-repo registry is `"official"`; anything resolved through a tap, or
  installed directly from a source URL with no registry entry at all, is `"community"` - a
  tap's own index cannot claim a higher tier than that, since nothing in it was reviewed by
  anyone but whoever runs the tap.

  **Updates are pinned to the exact source a skill was installed from**
  (`Pepe.Config.installed_skill/1`'s `"source"` field): `update/1` re-fetches from that exact
  source, and if the name now resolves to a *different* source in the registries, it refuses
  rather than silently switching - a same-named skill from a different registry can only ever
  replace an installed one via an explicit `install/2` with `force: true`, never `update/1`.
  """

  alias Pepe.Config
  alias Pepe.Skills
  alias Pepe.Skills.Sentinel
  alias Pepe.Sourcing

  @doc "Path to the bundled default registry, shipped in-repo."
  def bundled_registry_path, do: Application.app_dir(:pepe, "priv/skills_registry.json")

  @doc """
  Every entry across the bundled registry and every tap, as `{name, %{"source" => ..., ...},
  trust_level}`. The bundled registry is checked first, so it wins a name collision with a tap.
  """
  @spec all_entries() :: [{String.t(), map(), String.t()}]
  def all_entries do
    bundled = read_registry_file(bundled_registry_path()) |> Enum.map(fn {name, e} -> {name, e, "official"} end)
    taps = Config.skill_taps() |> Enum.flat_map(fn tap -> fetch_tap_index(tap) |> Enum.map(fn {n, e} -> {n, e, "community"} end) end)

    (bundled ++ taps) |> Enum.uniq_by(fn {name, _e, _t} -> name end)
  end

  @doc "Search every registry/tap for `query` (matches the name or description, case-insensitively)."
  @spec search(String.t()) :: [%{name: String.t(), source: String.t(), trust_level: String.t()}]
  def search(query) do
    q = String.downcase(query)

    all_entries()
    |> Enum.filter(fn {name, entry, _trust} ->
      String.contains?(String.downcase(name), q) or String.contains?(String.downcase(entry["description"] || ""), q)
    end)
    |> Enum.map(fn {name, entry, trust} -> %{name: name, source: entry["source"], trust_level: trust} end)
  end

  @doc """
  Resolve `name` against the registries, or, when `name` is a PepeHub reference
  (`@handle/name`, or the package's own page URL - see `Pepe.PepeHub`), against PepeHub
  directly - checked first, since a scoped name is never something a bundled entry or a tap
  would use. `{:ok, source, trust_level}` or `:not_found` (a PepeHub reference that resolves
  to a plugin, not a skill, is also `:not_found` here - install that with `Pepe.Plugins`
  instead).
  """
  @spec resolve(String.t()) :: {:ok, String.t(), String.t()} | :not_found
  def resolve(name) do
    if Pepe.PepeHub.reference?(name), do: resolve_from_hub(name), else: resolve_from_registries(name)
  end

  defp resolve_from_hub(name) do
    case Pepe.PepeHub.resolve(name) do
      {:ok, %{kind: "skill", download_url: url, trust: trust}} -> {:ok, url, trust}
      _ -> :not_found
    end
  end

  defp resolve_from_registries(name) do
    case Enum.find(all_entries(), fn {n, _e, _t} -> n == name end) do
      {_name, entry, trust} -> {:ok, entry["source"], trust}
      nil -> :not_found
    end
  end

  @doc """
  Install `name`: resolved against the registries, or (with `source: url_or_path` in `opts`)
  fetched directly from that source instead - always `"community"` trust, since bypassing the
  registries means nothing vouches for it. `force: true` installs past a `:danger` verdict.
  Returns `{:ok, name, scan}` or `{:error, reason}`.

  A PepeHub reference is placed and registered under its bare package slug, not the
  `@handle/name` it was resolved from (`Pepe.PepeHub.local_name/1`) - `resolve/1` still sees
  the full reference, since that's what PepeHub itself needs to look it up.
  """
  @spec install(String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def install(name, opts \\ []) do
    local_name = Pepe.PepeHub.local_name(name)

    case opts[:source] do
      nil ->
        case resolve(name) do
          {:ok, source, trust} -> do_install(local_name, source, trust, opts)
          :not_found -> {:error, :not_found}
        end

      source when is_binary(source) ->
        do_install(local_name, source, "community", opts)
    end
  end

  @doc """
  Update one installed skill (or, with `nil`, every installed skill) from the exact source it
  was installed from. Refuses (does not silently re-source) if the name now resolves to a
  different source than the one pinned at install. Returns `{:ok, [name]}` (updated) mixed
  with `{:error, {name, reason}}` entries when updating "every skill", or a bare
  `{:ok, name, scan} | {:error, reason}` for a single named update.
  """
  @spec update(String.t() | nil) :: term()
  def update(nil) do
    Config.installed_skills()
    |> Map.keys()
    |> Enum.map(fn name -> {name, update(name)} end)
  end

  def update(name) when is_binary(name) do
    case Config.installed_skill(name) do
      nil ->
        {:error, :not_found}

      %{"source" => pinned_source, "trust_level" => trust} ->
        case resolve(name) do
          {:ok, ^pinned_source, resolved_trust} -> do_install(name, pinned_source, resolved_trust, [])
          {:ok, other_source, _resolved_trust} -> {:error, {:source_changed, pinned_source, other_source}}
          :not_found -> do_install(name, pinned_source, trust || "community", [])
        end
    end
  end

  @doc "Remove an installed skill (the file and its marketplace provenance)."
  @spec remove(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def remove(name) do
    file = Path.join(Skills.user_dir(), name <> ".md")
    dir = Path.join(Skills.user_dir(), name)

    cond do
      File.regular?(file) ->
        File.rm!(file)
        Config.remove_installed_skill(name)
        {:ok, name}

      File.dir?(dir) ->
        File.rm_rf!(dir)
        Config.remove_installed_skill(name)
        {:ok, name}

      true ->
        {:error, :not_found}
    end
  end

  @doc "Every installed skill's marketplace provenance."
  @spec list_installed() :: [map()]
  def list_installed do
    Config.installed_skills()
    |> Enum.map(fn {name, meta} -> Map.put(meta, "name", name) end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Re-scan one installed skill's CURRENT content (or, with `nil`, every installed skill) - a
  skill that passed at install time can still be worth re-checking after the Sentinel patterns
  themselves improve, or just periodically.
  """
  @spec audit(String.t() | nil) :: [%{name: String.t(), verdict: atom(), findings: list()}]
  def audit(nil), do: Config.installed_skills() |> Map.keys() |> Enum.map(&audit_one/1)
  def audit(name) when is_binary(name), do: [audit_one(name)]

  # A package (a directory installed under its own name) gets every non-doc file
  # re-scanned too, same as at install time - a script that was clean when it was
  # installed is still worth catching if the Sentinel's patterns have improved since.
  defp audit_one(name) do
    package_dir = Path.join(Skills.user_dir(), name)
    if File.dir?(package_dir), do: audit_package(name, package_dir), else: audit_single(name)
  end

  defp audit_single(name) do
    case Skills.read(name) do
      {:ok, content} ->
        scan = Sentinel.scan(content)
        %{name: name, verdict: scan.verdict, findings: scan.findings}

      _ ->
        %{name: name, verdict: :not_found, findings: []}
    end
  end

  defp audit_package(name, dir) do
    case dir |> Skills.package_entry() |> read_doc() do
      {:ok, content} ->
        scan = package_scan(dir, content)
        %{name: name, verdict: scan.verdict, findings: scan.findings}

      _ ->
        %{name: name, verdict: :not_found, findings: []}
    end
  end

  defp read_doc(nil), do: {:error, :not_found}
  defp read_doc(path), do: File.read(path)

  # --- install pipeline --------------------------------------------------------------

  defp do_install(name, source, trust_level, opts) do
    with {:ok, staged, cleanup} <- Sourcing.stage(source, ".md", &String.ends_with?(&1, ".md")) do
      try do
        case prepare(staged, name) do
          {:ok, placement, content, scan} ->
            if scan.verdict == :danger and opts[:force] != true do
              {:error, {:unsafe, scan}}
            else
              place(placement, name)

              Config.put_installed_skill(name, %{
                "source" => source,
                "hash" => content_hash(content),
                "trust_level" => trust_level,
                "installed_at" => DateTime.to_iso8601(DateTime.utc_now())
              })

              {:ok, name, scan}
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        cleanup.()
      end
    end
  end

  defp prepare(%{type: :file, path: path}, _name) do
    with {:ok, content} <- File.read(path), do: {:ok, {:file, content}, content, Sentinel.scan(content)}
  end

  defp prepare(%{type: :dir, path: path}, name) do
    if File.regular?(Path.join(path, "SKILL.md")) do
      prepare_package(path)
    else
      prepare_single(path, name)
    end
  end

  defp prepare_single(path, name) do
    exact = Path.join(path, name <> ".md")
    file = if File.regular?(exact), do: exact, else: Path.wildcard(Path.join(path, "*.md")) |> List.first()

    case file && File.read(file) do
      {:ok, content} -> {:ok, {:file, content}, content, Sentinel.scan(content)}
      _ -> {:error, :no_skill_file}
    end
  end

  defp prepare_package(dir) do
    with {:ok, content} <- dir |> Skills.package_entry() |> read_doc() do
      {:ok, {:package, dir}, content, package_scan(dir, content)}
    end
  end

  # The doc gets the prose-oriented prompt-injection scan (Sentinel.scan/1); every other
  # file gets the deep AST-plus-text scan (Sentinel.scan_code/2) - it degrades gracefully
  # to just the text pass on anything that isn't Elixir (see Sentinel's own moduledoc),
  # so a Python/JS/bash script still gets checked for the secrets-path/obfuscation
  # patterns that scan applies, not skipped just because it isn't `.exs`.
  defp package_scan(dir, doc_content) do
    doc_path = Skills.package_entry(dir)
    code_scans = dir |> package_files(doc_path) |> Enum.map(&scan_code_file(&1, dir))
    Sentinel.merge([Sentinel.scan(doc_content) | code_scans])
  end

  defp package_files(dir, doc_path) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&(File.regular?(&1) and &1 != doc_path))
  end

  defp scan_code_file(path, base_dir), do: Sentinel.scan_code(File.read!(path), Path.relative_to(path, base_dir))

  defp place({:file, content}, name) do
    File.mkdir_p!(Skills.user_dir())
    File.write!(Path.join(Skills.user_dir(), name <> ".md"), content)
  end

  defp place({:package, dir}, name) do
    dest = Path.join(Skills.user_dir(), name)
    File.mkdir_p!(Skills.user_dir())
    File.rm_rf!(dest)
    File.cp_r!(dir, dest)
  end

  defp content_hash(content), do: "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))

  # --- registry/tap index fetching ----------------------------------------------------

  defp read_registry_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body),
         true <- is_map(map) do
      map
    else
      _ -> %{}
    end
  end

  # A tap is either a direct URL to a skills_registry.json-shaped index, or a GitHub repo
  # (its index is fetched from that repo's root, trying main then master).
  defp fetch_tap_index(tap) do
    tap
    |> tap_index_urls()
    |> Enum.find_value(&fetch_json/1)
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp tap_index_urls(tap) do
    case URI.parse(tap) do
      %{host: host, path: path} when host in ["github.com", "www.github.com"] and is_binary(path) ->
        github_index_urls(tap, Sourcing.github_target(path))

      _ ->
        [tap]
    end
  end

  defp github_index_urls(_tap, {owner, repo, branch}) do
    branches = if branch, do: [branch], else: ["main", "master"]
    Enum.map(branches, &"https://raw.githubusercontent.com/#{owner}/#{repo}/#{&1}/skills_registry.json")
  end

  defp github_index_urls(tap, nil), do: [tap]

  defp fetch_json(url) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> body
      {:ok, %{status: 200, body: body}} when is_binary(body) -> decode_json(body)
      _ -> nil
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end
end
