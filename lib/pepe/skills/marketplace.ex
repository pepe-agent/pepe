defmodule Pepe.Skills.Marketplace do
  @moduledoc """
  Install/search/update skills from registries: a bundled default (shipped in-repo, curated,
  currently empty - there is no hosted official registry yet, only the mechanism) plus any
  homebrew-style "taps" the operator adds (`Pepe.Config.skill_taps/0`), not a central service.

  Mirrors `Pepe.Plugins`' install shape (stage -> Sentinel scan -> refuse on `:danger` unless
  `--force` -> place), sharing `Pepe.Sourcing` for the download/stage half.

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

  @doc "Resolve `name` against the registries. `{:ok, source, trust_level}` or `:not_found`."
  @spec resolve(String.t()) :: {:ok, String.t(), String.t()} | :not_found
  def resolve(name) do
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
  """
  @spec install(String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def install(name, opts \\ []) do
    case opts[:source] do
      nil ->
        case resolve(name) do
          {:ok, source, trust} -> do_install(name, source, trust, opts)
          :not_found -> {:error, :not_found}
        end

      source when is_binary(source) ->
        do_install(name, source, "community", opts)
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
    path = Path.join(Skills.user_dir(), name <> ".md")

    if File.regular?(path) do
      File.rm!(path)
      Config.remove_installed_skill(name)
      {:ok, name}
    else
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

  defp audit_one(name) do
    case Skills.read(name) do
      {:ok, content} ->
        scan = Sentinel.scan(content)
        %{name: name, verdict: scan.verdict, findings: scan.findings}

      _ ->
        %{name: name, verdict: :not_found, findings: []}
    end
  end

  # --- install pipeline --------------------------------------------------------------

  defp do_install(name, source, trust_level, opts) do
    with {:ok, staged, cleanup} <- Sourcing.stage(source, ".md", &String.ends_with?(&1, ".md")) do
      try do
        case staged_content(staged, name) do
          {:ok, content} ->
            scan = Sentinel.scan(content)

            if scan.verdict == :danger and opts[:force] != true do
              {:error, {:unsafe, scan}}
            else
              place(name, content)

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

  defp staged_content(%{type: :file, path: path}, _name), do: File.read(path)

  defp staged_content(%{type: :dir, path: path}, name) do
    exact = Path.join(path, name <> ".md")

    if File.regular?(exact) do
      File.read(exact)
    else
      case Path.wildcard(Path.join(path, "*.md")) do
        [file | _] -> File.read(file)
        [] -> {:error, :no_skill_file}
      end
    end
  end

  defp place(name, content) do
    File.mkdir_p!(Skills.user_dir())
    File.write!(Path.join(Skills.user_dir(), name <> ".md"), content)
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
        case Sourcing.github_target(path) do
          {owner, repo, branch} ->
            branches = if branch, do: [branch], else: ["main", "master"]
            Enum.map(branches, &"https://raw.githubusercontent.com/#{owner}/#{repo}/#{&1}/skills_registry.json")

          nil ->
            [tap]
        end

      _ ->
        [tap]
    end
  end

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
