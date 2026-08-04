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
  A plugin's declared settings schema: the `"config"` array from its `manifest.json`
  (a list of `%{"key", "label", "type", "hint"}` fields), or `[]` if it declares none.
  Lets a plugin surface its own credentials/options form on the dashboard.
  """
  def config_schema(name) do
    case Enum.find(packages(), &(&1.name == name)) do
      %{manifest: %{"config" => fields}} when is_list(fields) -> fields
      _ -> []
    end
  end

  @doc """
  Read one saved setting for a plugin, interpolating `${ENV_VAR}` refs. Returns `default`
  when unset. This is what a plugin's own code calls to get its dashboard-entered config.
  """
  def config(name, key, default \\ nil) do
    case Pepe.Config.plugin_config(name)[key] do
      nil -> default
      "" -> default
      value -> Pepe.Config.interpolate(value)
    end
  end

  @doc """
  A servable static asset package: a directory (user-installed under `dir()`, or a
  first-party one bundled under `priv/builtin_plugins/`, user wins on a name collision -
  same override rule as `Pepe.Skills`) whose `manifest.json` declares an `"assets"` array.

  Unlike tools/channels (inferred from exported functions), asset exposure is always an
  explicit allowlist: a package only serves the exact file names it lists, so a plugin
  can never accidentally expose its `.exs` source or other files over HTTP.
  """
  def assets(name) do
    case package_dir(name) do
      nil ->
        []

      dir ->
        case read_manifest(dir) do
          %{"assets" => list} when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> []
        end
    end
  end

  @doc """
  Resolve a servable asset for `name`/`requested_path` (e.g. `"pepe-widget"`, `"widget.js"`).
  The path must be declared in that package's `"assets"` list and must not escape the
  package directory. Returns `{:ok, absolute_path}` or `{:error, :not_found}`.
  """
  def asset_path(name, requested_path) do
    with dir when is_binary(dir) <- package_dir(name),
         true <- requested_path in assets(name),
         abs = Path.join(dir, requested_path),
         true <- within?(dir, abs),
         true <- File.regular?(abs) do
      {:ok, abs}
    else
      _ -> {:error, :not_found}
    end
  end

  defp builtin_dir, do: Application.app_dir(:pepe, "priv/builtin_plugins")

  # A user-installed package wins over a built-in one of the same name.
  defp package_dir(name) do
    user = Path.join(dir(), name)
    builtin = Path.join(builtin_dir(), name)

    cond do
      File.dir?(user) -> user
      File.dir?(builtin) -> builtin
      true -> nil
    end
  end

  # Guards `..`/absolute-path escapes: the expanded path must still live inside dir.
  defp within?(dir, path) do
    expanded_dir = Path.expand(dir)
    expanded_path = Path.expand(path)
    expanded_path == expanded_dir or String.starts_with?(expanded_path, expanded_dir <> "/")
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

  defp scan_staged(%{type: :file, path: path}), do: scan_files([path])
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

  # A package root is the dir holding manifest.json (or a .exs if there's no manifest) -
  # generalized in Pepe.Sourcing as a predicate over a candidate file's basename.
  defp stage(src), do: Pepe.Sourcing.stage(src, ".exs", &plugin_root_marker?/1)

  defp plugin_root_marker?(@manifest), do: true
  defp plugin_root_marker?(name), do: String.ends_with?(name, ".exs")

  # --- placement: copy the staged plugin into the plugins dir ----------------------

  defp place(%{type: :file, path: path}) do
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
    case guard(path) do
      :ok ->
        path |> Code.compile_file() |> Enum.map(&elem(&1, 0))

      {:danger, scan} ->
        Logger.error(
          "[plugins] refusing to load #{Path.basename(path)}: Sentinel flagged it dangerous " <>
            "(#{scan_summary(scan)}). Remove it, or re-install with a reviewed version."
        )

        []
    end
  rescue
    error ->
      Logger.warning("[plugins] failed to load #{path}: #{Exception.message(error)}")
      []
  end

  # Scan every plugin at load, not only at `install/1`. A `.exs` can reach the plugins dir
  # without going through install (a `write_file`, a restored bundle, a hand-edit), and it is
  # compiled and run in-process with full access. The same `:danger` bar that blocks an install
  # blocks a load, so a plugin that got there some other way cannot execute code the operator
  # never reviewed.
  defp guard(path) do
    case File.read(path) do
      {:ok, src} ->
        scan = Pepe.Skills.Sentinel.scan_code(src, Path.basename(path))
        if scan.verdict == :danger, do: {:danger, scan}, else: :ok

      _ ->
        :ok
    end
  end

  defp scan_summary(%{findings: [_ | _] = findings}) do
    findings |> Enum.take(3) |> Enum.map_join("; ", fn f -> "#{f[:category]}: #{f[:match]}" end)
  end

  defp scan_summary(_), do: "no detail"

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

  defp ensure_exs(name), do: if(String.ends_with?(name, ".exs"), do: name, else: name <> ".exs")
end
