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

  # Deliberately NOT cached, despite sitting on a hot path (Pepe.Permissions.gate/3, via
  # Policy.veto/3, on every tool call; Pepe.Hooks.provider/1 at least twice a turn): every
  # invalidation signal available from here is either too coarse or too easy to miss.
  # `File.stat/1`'s mtime is second-granularity in the VM regardless of the underlying
  # filesystem's own precision, so a write immediately followed by a read (install a plugin,
  # then use it - the normal, expected CLI/dashboard flow) can land in the same wall-clock
  # second and read stale - a real bug, not a theoretical one: it was caught live by this
  # module's own test suite writing a plugin file and asserting it's visible right after. A
  # plain TTL has the same problem for longer, and on a path that includes policy-veto
  # plugin resolution, "occasionally stale for up to N seconds" is not a trade a security
  # gate should make for a `Path.wildcard` call that, for the common case (a handful of
  # plugin files on local disk), is microseconds. `load/1` below still caches each file's
  # own *compiled modules* by mtime, so no plugin is ever recompiled on every call - only
  # the directory listing itself is re-walked.
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
  Call `mod.fun(args)` guarded against a raise/throw/exit. Returns `{:ok, result}`, or
  `:error` (logged) on failure. For the metadata probes every plugin surface calls to
  route a request to the right module (`name/0`, `slot/0`, `api/0`, ...) - these run in
  the caller's own process, before any per-call isolation (`Pepe.Slots.Guard`,
  `Pepe.Gateways.PluginSupervisor`'s own children) has a chance to kick in, so a broken
  plugin's probe must not crash whoever was just trying to route around it.
  """
  @spec safe_call(module(), atom(), list()) :: {:ok, term()} | :error
  def safe_call(mod, fun, args \\ []) do
    {:ok, apply(mod, fun, args)}
  rescue
    error -> warn(mod, fun, args, Exception.message(error))
  catch
    kind, reason -> warn(mod, fun, args, "#{kind}: #{inspect(reason)}")
  end

  defp warn(mod, fun, args, detail) do
    Logger.warning("[plugins] #{inspect(mod)}.#{fun}/#{length(args)} failed: #{detail}")
    :error
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
  Install a plugin from `src`: a local `.exs`, a local directory, a `.tar.gz`/`.tgz`, an
  `http(s)` URL to any of those (a GitHub repo URL is fetched as its source archive), or a
  PepeHub reference (`@handle/name`, or the package's own page URL - see `Pepe.PepeHub`).

  The staged code is scanned with `Pepe.Skills.Sentinel` before it is placed. A `:danger`
  verdict blocks the install (`{:error, {:unsafe, scan}}`) unless `opts[:force]` is set.
  Returns `{:ok, name, scan}` on success (the scan may still carry cautions), or
  `{:error, reason}` - including `{:error, {:wrong_kind, "skill"}}` when a PepeHub reference
  resolves to a skill, not a plugin (install that with `Pepe.Skills.Marketplace` instead).
  """
  def install(src, opts \\ []) do
    with {:ok, src} <- resolve_hub_ref(src),
         {:ok, staged, cleanup} <- stage(src) do
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
  # generalized in Pepe.Sourcing as a rank over a candidate file's basename.
  defp stage(src), do: Pepe.Sourcing.stage(src, ".exs", &plugin_root_rank/1)

  # Not a PepeHub reference at all -> src passes straight through to stage/1 unchanged,
  # exactly as it always has for a path/archive/URL.
  defp resolve_hub_ref(src) do
    if Pepe.PepeHub.reference?(src) do
      case Pepe.PepeHub.resolve(src) do
        {:ok, %{kind: "plugin", download_url: url}} -> {:ok, url}
        {:ok, %{kind: other}} -> {:error, {:wrong_kind, other}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, src}
    end
  end

  defp plugin_root_rank(@manifest), do: 0
  defp plugin_root_rank(name), do: if(String.ends_with?(name, ".exs"), do: 1, else: false)

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

  # A hanging `.exs` (a blocking `receive` with no `after`, an infinite loop at the top
  # level) would otherwise freeze `Code.compile_file/1` forever, in the caller's own
  # process - and every plugin-facing surface (Pepe.Tools.get/1, Pepe.LLM.Adapters.get/1,
  # Pepe.Slots.Guard.call/3, ...) calls through here, so one bad file would take the whole
  # installation down with it. `compile/1` is run in its own supervised, unlinked Task with
  # a hard deadline; a timeout is cached exactly like a successful compile (keyed by the
  # same mtime), so a permanently-hung file costs the wait once, not on every call - fixing
  # it (which changes its mtime) is what makes it eligible to retry.
  @compile_timeout 5_000

  defp load(path) do
    key = {__MODULE__, path}

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :persistent_term.get(key, nil) do
          {^mtime, mods} -> mods
          _ -> load_locked(key, mtime, path)
        end

      _ ->
        []
    end
  end

  # Two callers can miss the cache for the same file at once (a LiveView resolving an
  # agent's hooks while the session's runtime resolves the same list, say). Unserialized,
  # both would `Code.compile_file/1` the same module concurrently: one wins, the other
  # dies with "cannot define module ... because it is currently being defined", is
  # rescued into `[]`, and - since both then write the cache under the same mtime - can
  # overwrite the winner's result, leaving the plugin *permanently* unloaded until its
  # file is touched. A per-path lock (same `:global.trans` pattern as
  # `Pepe.Store.bootstrap/0`) with a second cache check inside makes exactly one caller
  # compile; everyone else waits briefly and reuses its result.
  defp load_locked(key, mtime, path) do
    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        {^mtime, mods} -> mods
        _ -> cache(key, mtime, compile_with_timeout(path))
      end
    end)
  end

  defp cache(key, mtime, mods) do
    :persistent_term.put(key, {mtime, mods})
    mods
  end

  # `Pepe.Plugins.TaskSupervisor` lives in `Pepe.Application`'s own supervision tree,
  # which a lightweight, config-only CLI command (`mix pepe agent add`, `plugin route
  # enable`, ... - anything routed through `Mix.Tasks.Pepe.with_config/1`, as opposed to
  # `with_app/2`) never starts at all - not gated off, simply never brought up, since
  # these commands were never expected to need the live app. That was true until any
  # plugin actually existed on disk: the moment one does, `Pepe.Tools.names/0`/
  # `Pepe.PluginRoute.status/0`/anything else that enumerates plugins reaches here and
  # would otherwise crash outright with a `GenServer.call` on a nonexistent process -
  # found live, running `mix pepe agent add`/`plugin route enable` against a real
  # install with plugins present.
  #
  # The fallback still gets the SAME timeout/crash protection as the normal path - an
  # ephemeral, throwaway `Task.Supervisor` started just for this one call, not a bare
  # `compile(path)`. A bare call was the first fix here, on the reasoning that a
  # lightweight CLI command is short-lived and the operator can just Ctrl-C a hang - but
  # the actual condition this branch fires on is "the named supervisor isn't running",
  # not "I am specifically a lightweight CLI command", and that's a strictly bigger set:
  # any test that doesn't start `Pepe.Application` (most of this session's own new test
  # files) hits this path too, and `test/pepe/plugins_test.exs` already has a fixture
  # that hangs forever on purpose - a bare synchronous call would have hung the whole
  # test run on it instead of timing out. `Task.async/1` (bare, no supervisor at all)
  # isn't a safe substitute either: it LINKS to the caller, so a crash in the task would
  # propagate straight to the caller instead of yielding a clean `{:exit, reason}` the
  # way `async_nolink` does - which is the entire reason this codebase uses
  # `Task.Supervisor.async_nolink/2` everywhere else instead of bare `Task.async/1`.
  defp compile_with_timeout(path) do
    case Process.whereis(Pepe.Plugins.TaskSupervisor) do
      nil -> compile_with_timeout_ephemeral(path)
      pid -> run_bounded(pid, path)
    end
  end

  defp compile_with_timeout_ephemeral(path) do
    {:ok, sup} = Task.Supervisor.start_link()

    try do
      run_bounded(sup, path)
    after
      Supervisor.stop(sup)
    end
  end

  defp run_bounded(supervisor, path) do
    case start_bounded(supervisor, path) do
      {:ok, task} -> await_bounded(task, path)
      :overloaded -> []
    end
  end

  # `Task.Supervisor.async_nolink/2` raises synchronously, in the caller's own process,
  # if the supervisor is already at `max_children` - a burst of concurrent plugin loads
  # (several conversations calling `Pepe.Tools.by_name/0`, `Pepe.Hooks.registry/0`, ...
  # all at once) would otherwise crash whoever happened to trigger the load, exactly the
  # thing this whole module exists to prevent. Not cached: the caller gets `[]` for this
  # one lookup, and the next call to `modules/0` tries again once load has eased.
  defp start_bounded(supervisor, path) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fn -> compile(path) end)}
  rescue
    RuntimeError ->
      Logger.warning("[plugins] #{Path.basename(path)} skipped: too many plugins loading concurrently")

      :overloaded
  end

  defp await_bounded(task, path) do
    case Task.yield(task, @compile_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, mods} ->
        mods

      {:exit, reason} ->
        Logger.warning("[plugins] #{Path.basename(path)} crashed while loading: #{inspect(reason)}")
        []

      nil ->
        Logger.error(
          "[plugins] #{Path.basename(path)} took longer than #{@compile_timeout}ms to load - " <>
            "skipping it (fix or remove the file, which changes its mtime and makes it eligible to retry)"
        )

        []
    end
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
  catch
    # A `throw`/`exit` at a plugin's own top level (not a `raise`) used to only ever
    # reach here through compile_with_timeout_supervised/1's Task boundary, which
    # catches it regardless of whether this function does - compile_with_timeout/1's
    # synchronous fallback (no Task, no supervisor) calls straight into this function,
    # so without this clause the same plugin that's handled fine on a normal boot would
    # crash a lightweight CLI command outright the moment it isn't.
    kind, reason ->
      Logger.warning("[plugins] failed to load #{path}: #{kind}: #{inspect(reason)}")
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
