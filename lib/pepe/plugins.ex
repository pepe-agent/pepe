defmodule Pepe.Plugins do
  @moduledoc """
  Loader and installer for user **plugins** under `<PEPE_HOME>/plugins/`, compiled at
  runtime (no rebuild of the app). A plugin is either a bare `.exs` file or a **package**:
  a directory with a `manifest.json` and one or more `.exs` files (and, later, assets).

  Every `.exs` under the plugins dir (recursively) is compiled once and cached by mtime.
  Each consumer filters the loaded modules for the shape it wants, so one loader serves
  every extensible surface:

    * a **tool** exports `name/0`, `spec/0`, `run/2` (see `Pepe.Tools`);
    * a **channel** exports `name/0` plus the `Pepe.Webhooks.Provider` callbacks.

  `install/1` accepts a local `.exs`, a local directory, a `.tar.gz`/`.tgz` archive, or an
  `http(s)` URL to any of those, and unrolls it into place (reading the manifest to name a
  package). A plugin is ordinary Elixir with full access to the app, so installing one is
  a trust decision, like adding any dependency.
  """

  require Logger

  @manifest "manifest.json"

  @doc "Directory holding installed plugins."
  def dir, do: Path.join(Pepe.Config.home(), "plugins")

  @doc "Every module defined by a plugin `.exs` (recursively), compiled once per file."
  def modules do
    Path.wildcard(Path.join(dir(), "**/*.exs"))
    |> Enum.sort()
    |> Enum.flat_map(&load/1)
  end

  @doc "Loaded plugin modules that export every `{fun, arity}` in `funs`."
  def implementing(funs) do
    Enum.filter(modules(), fn mod ->
      Code.ensure_loaded?(mod) and Enum.all?(funs, fn {f, a} -> function_exported?(mod, f, a) end)
    end)
  end

  @doc """
  Installed plugins as `%{name, kind, manifest}`: bare `.exs` files (`kind: :file`) and
  package directories with a manifest (`kind: :package`).
  """
  def packages do
    files =
      case File.ls(dir()) do
        {:ok, entries} -> entries
        _ -> []
      end

    bare =
      files
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.map(fn f -> %{name: Path.rootname(f), kind: :file, manifest: nil} end)

    pkgs =
      files
      |> Enum.map(&Path.join(dir(), &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(fn d -> %{name: Path.basename(d), kind: :package, manifest: read_manifest(d)} end)

    Enum.sort_by(bare ++ pkgs, & &1.name)
  end

  @doc """
  Install a plugin from `src`: a local `.exs`, a local directory, a `.tar.gz`/`.tgz`, or
  an `http(s)` URL to any of those (a GitHub repo URL is fetched as its source archive).

  The staged code is scanned with `Pepe.Skills.Sentinel` before it is placed. A `:danger`
  verdict blocks the install (`{:error, {:unsafe, scan}}`) unless `opts[:force]` is set.
  Returns `{:ok, name, scan}` on success (the scan may still carry cautions), or
  `{:error, reason}`.
  """
  def install(src, opts \\ []) do
    with {:ok, staged, cleanup} <- stage(src) do
      try do
        scan = scan_staged(staged)

        if scan.verdict == :danger and opts[:force] != true do
          {:error, {:unsafe, scan}}
        else
          case place(staged) do
            {:ok, name} -> {:ok, name, scan}
            error -> error
          end
        end
      after
        cleanup.()
      end
    end
  end

  @doc "Security-scan the plugin at `src` without installing it. Returns a Sentinel scan."
  def scan(src) do
    with {:ok, staged, cleanup} <- stage(src) do
      try do
        scan_staged(staged)
      after
        cleanup.()
      end
    end
  end

  defp scan_staged(%{type: :exs, path: path}), do: scan_files([path])
  defp scan_staged(%{type: :dir, path: path}), do: scan_files(Path.wildcard(Path.join(path, "**/*.exs")))

  defp scan_files(paths) do
    paths
    |> Enum.map(fn p ->
      case File.read(p) do
        {:ok, src} -> Pepe.Skills.Sentinel.scan_code(src, Path.basename(p))
        _ -> %{verdict: :safe, findings: []}
      end
    end)
    |> Pepe.Skills.Sentinel.merge()
  end

  @doc "Remove an installed plugin by name (a bare file or a package directory)."
  def remove(name) do
    file = Path.join(dir(), ensure_exs(name))
    package = Path.join(dir(), name)

    cond do
      File.exists?(file) ->
        File.rm(file)
        {:ok, name}

      File.dir?(package) ->
        File.rm_rf(package)
        {:ok, name}

      true ->
        {:error, :not_found}
    end
  end

  # --- staging: turn any source into a local path we can inspect -------------------

  # Returns {:ok, %{type: :exs|:dir, path: ...}, cleanup_fun} or {:error, reason}.
  defp stage("http" <> _ = url) do
    cond do
      github_repo?(url) -> stage_github(url)
      String.ends_with?(url, ".exs") -> stage_download(url, :exs)
      true -> stage_download(url, :archive)
    end
  end

  defp stage(path) do
    cond do
      not (File.exists?(path) or File.dir?(path)) -> {:error, :not_found}
      File.dir?(path) -> {:ok, %{type: :dir, path: path}, fn -> :ok end}
      archive?(path) -> stage_archive(path, fn -> :ok end)
      String.ends_with?(path, ".exs") -> {:ok, %{type: :exs, path: path}, fn -> :ok end}
      true -> {:error, :unsupported_source}
    end
  end

  # Download a URL, then treat it as a single `.exs` or as an archive to extract.
  defp stage_download(url, kind) do
    case download(url) do
      {:ok, tmp} when kind == :exs -> {:ok, %{type: :exs, path: with_ext(tmp, url)}, fn -> File.rm(tmp) end}
      {:ok, tmp} -> stage_archive(tmp, fn -> File.rm(tmp) end)
      error -> error
    end
  end

  # A GitHub repo URL is fetched as a source archive. `owner/repo`, optionally
  # `.../tree/<branch>`; when no branch is given, `main` then `master` are tried.
  defp github_repo?(url) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(path) ->
        host in ["github.com", "www.github.com"] and github_target(path) != nil and
          not archive?(url) and not String.ends_with?(url, ".exs")

      _ ->
        false
    end
  end

  defp stage_github(url) do
    {owner, repo, branch} = github_target(URI.parse(url).path)
    branches = if branch, do: [branch], else: ["main", "master"]
    urls = Enum.map(branches, &"https://codeload.github.com/#{owner}/#{repo}/tar.gz/refs/heads/#{&1}")

    case download_first(urls) do
      {:ok, tmp} -> stage_archive(tmp, fn -> File.rm(tmp) end)
      error -> error
    end
  end

  @doc false
  # `/owner/repo` or `/owner/repo/tree/branch` -> {owner, repo, branch|nil}, else nil.
  def github_target(path) do
    case path |> to_string() |> String.trim("/") |> String.split("/") do
      [owner, repo | rest] when owner != "" and repo != "" ->
        branch =
          case rest do
            ["tree", b | _] when b != "" -> b
            _ -> nil
          end

        {owner, String.replace_suffix(repo, ".git", ""), branch}

      _ ->
        nil
    end
  end

  defp download_first([url | rest]) do
    case download(url) do
      {:ok, tmp} -> {:ok, tmp}
      _ when rest != [] -> download_first(rest)
      error -> error
    end
  end

  defp download_first([]), do: {:error, :not_found}

  # A downloaded temp file has no extension; give it the source's so `place/1` names it.
  defp with_ext(tmp, url) do
    name = url |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.basename()
    dest = if name != "", do: Path.join(Path.dirname(tmp), name), else: tmp <> ".exs"
    if dest != tmp, do: File.rename(tmp, dest)
    dest
  end

  defp stage_archive(archive_path, cleanup) do
    tmp = Path.join(System.tmp_dir!(), "pepe_plugin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    case :erl_tar.extract(String.to_charlist(archive_path), [:compressed, {:cwd, String.to_charlist(tmp)}]) do
      :ok ->
        {:ok, %{type: :dir, path: package_root(tmp)},
         fn ->
           cleanup.()
           File.rm_rf(tmp)
           :ok
         end}

      {:error, reason} ->
        File.rm_rf(tmp)
        cleanup.()
        {:error, {:extract, reason}}
    end
  end

  # The package root inside an extracted archive: the dir holding the manifest (or a `.exs`
  # if there's no manifest), else the extraction root.
  defp package_root(tmp) do
    cond do
      match = Enum.at(Path.wildcard(Path.join(tmp, "**/#{@manifest}")), 0) -> Path.dirname(match)
      match = Enum.at(Path.wildcard(Path.join(tmp, "**/*.exs")), 0) -> Path.dirname(match)
      true -> tmp
    end
  end

  # --- placement: copy the staged plugin into the plugins dir ----------------------

  defp place(%{type: :exs, path: path}) do
    File.mkdir_p!(dir())
    name = ensure_exs(Path.basename(path))
    File.cp!(path, Path.join(dir(), name))
    {:ok, name}
  end

  defp place(%{type: :dir, path: path}) do
    name = manifest_name(path) || Path.basename(path)

    if has_exs?(path) do
      dest = Path.join(dir(), name)
      File.rm_rf(dest)
      File.mkdir_p!(dest)
      File.cp_r!(path, dest)
      {:ok, name}
    else
      {:error, :no_plugin_files}
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp load(path) do
    key = {__MODULE__, path}

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :persistent_term.get(key, nil) do
          {^mtime, mods} -> mods
          _ -> cache(key, mtime, compile(path))
        end

      _ ->
        []
    end
  end

  defp cache(key, mtime, mods) do
    :persistent_term.put(key, {mtime, mods})
    mods
  end

  defp compile(path) do
    path |> Code.compile_file() |> Enum.map(&elem(&1, 0))
  rescue
    error ->
      Logger.warning("[plugins] failed to load #{path}: #{Exception.message(error)}")
      []
  end

  defp download(url) do
    case Req.get(url, receive_timeout: 30_000, redirect: true) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        tmp = Path.join(System.tmp_dir!(), "pepe_dl_#{System.unique_integer([:positive])}")
        File.write!(tmp, body)
        {:ok, tmp}

      {:ok, %{status: s}} ->
        {:error, {:http, s}}

      other ->
        other
    end
  end

  defp read_manifest(package_dir) do
    with {:ok, body} <- File.read(Path.join(package_dir, @manifest)),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> nil
    end
  end

  defp manifest_name(package_dir) do
    case read_manifest(package_dir) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp has_exs?(dir), do: Path.wildcard(Path.join(dir, "**/*.exs")) != []

  defp archive?(path), do: String.ends_with?(path, ".tar.gz") or String.ends_with?(path, ".tgz")

  defp ensure_exs(name), do: if(String.ends_with?(name, ".exs"), do: name, else: name <> ".exs")
end
