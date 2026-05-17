defmodule Pepe.Bundle do
  @moduledoc """
  Move a Pepe install, or one company out of it, as a single `.tgz`.

  Two archives, one shape, one restore. Both are a `~/.pepe` laid out inside a tarball, so
  `restore/2` unpacks either without needing to know which it is.

    * **Backup** (`mix pepe backup`) is the whole install: every company, every workspace, every
      session. It is the "don't lose this machine" archive, and it restores onto an empty box as
      the same machine.

    * **Extract** (`extract/2`) is one company, lifted out and **de-scoped to root**: its
      `company/agent` handles become bare names, so the archive is a fresh single-tenant install
      that happens to be that company. This is how a tenant that grew up inside a shared install
      leaves to run on its own server. You cannot get there by copying a folder, because the
      company's rows are threaded through the shared `config.json`; the de-scoping
      (`Pepe.Config.extract_config/1`) is the whole point.

  ## What travels, and what does not

  The config carries only the company's own agents, models, crons, watches, bots and tokens,
  plus any shared model a kept agent depends on. On disk, the company's agent workspaces
  (`companies/<co>/agents/*`), its `shared/`, and its usage ledger travel; the ledger's per-line
  `agent` handle is de-scoped in step with the config. Install-wide capability (`plugins/`,
  `skills/`) travels too, so an agent that leaned on a skill still works. Disposable state does
  **not**: the Mnesia cache rebuilds itself, and other tenants' traces and sessions are not this
  company's to carry.

  ## Secrets

  Secrets live outside the files as `${ENV_VAR}` references and are never written expanded, so
  they are not in the archive. Both `extract/2` and `restore/2` report the variables the archive
  references, so they can be provisioned on the destination; without them the config resolves to
  nothing where a secret should be.
  """

  alias Pepe.Config
  alias Pepe.Usage.Log

  @doc """
  Write a de-scoped, root-scoped archive of one `company` to `output` (a `.tgz` path; defaults
  to `./<company>-extract-YYYY-MM-DD.tgz` when nil - the date is the caller's to pass in via
  `opts[:today]` so this stays pure of the clock).

  Returns `{:ok, %{output: path, secrets: [...], shared_models: [...]}}` or `{:error, reason}`.
  """
  @spec extract(String.t(), keyword()) ::
          {:ok,
           %{
             output: String.t(),
             secrets: [String.t()],
             shared_models: [String.t()],
             literal_secrets: [String.t()]
           }}
          | {:error, term()}
  def extract(company, opts \\ []) do
    with {:ok, config, report} <- Config.extract_config(company) do
      today = opts[:today] || Date.utc_today()
      output = Path.expand(opts[:output] || "#{company}-extract-#{today}.tgz")
      stage = Path.join(System.tmp_dir!(), "pepe_extract_#{System.unique_integer([:positive])}")
      home_base = Path.basename(Config.home())

      try do
        root = Path.join(stage, home_base)
        File.mkdir_p!(root)
        # The staged config.json can hold a raw credential (an OAuth login's tokens, an inline
        # api_key), and the stage sits in a world-readable temp dir until it is tarred and
        # removed. Keep it private while it is there.
        File.chmod!(stage, 0o700)
        File.write!(Path.join(root, "config.json"), Jason.encode!(config, pretty: true))

        copy_company_agents(root, company, config)
        copy_company_shared(root, company)
        copy_usage(root, company)
        copy_global_capability(root)

        case tar(output, stage, home_base) do
          :ok -> {:ok, Map.put(report, :output, output)}
          {:error, _} = err -> err
        end
      after
        File.rm_rf(stage)
      end
    end
  end

  @doc """
  Unpack a `~/.pepe`-shaped archive (a backup or an extract) into `home` (defaults to the
  configured `PEPE_HOME`). Refuses to write over a non-empty `home` unless `force: true`, since
  a restore replaces what is there. Returns `{:ok, %{home, secrets, literal_secrets}}` or
  `{:error, reason}`; `secrets` are the env vars the restored config needs, `literal_secrets` the
  raw credentials the archive carried (see `Pepe.Config.literal_secrets/1`).

  The swap is **non-destructive on failure**: the archive is unpacked and copied into a sibling
  of `home` first, and the existing `home` is only replaced once that copy has fully succeeded.
  A mid-copy failure (disk full, a bad archive) leaves the old install exactly where it was
  rather than a half-wiped one.
  """
  @spec restore(String.t(), keyword()) ::
          {:ok, %{home: String.t(), secrets: [String.t()], literal_secrets: [String.t()]}}
          | {:error, term()}
  def restore(archive, opts \\ []) do
    home = opts[:home] || Config.home()

    cond do
      not File.regular?(archive) ->
        {:error, :no_archive}

      populated?(home) and not Keyword.get(opts, :force, false) ->
        {:error, :home_not_empty}

      true ->
        do_restore(archive, home)
    end
  end

  defp do_restore(archive, home) do
    tag = System.unique_integer([:positive])
    stage = Path.join(System.tmp_dir!(), "pepe_restore_#{tag}")
    incoming = "#{home}.incoming-#{tag}"
    File.mkdir_p!(stage)
    File.chmod!(stage, 0o700)

    try do
      with :ok <- untar(archive, stage),
           {:ok, root} <- locate_root(stage),
           :ok <- stage_copy(root, incoming) do
        swap_into_place(incoming, home)
        config = Path.join(home, "config.json")
        {:ok, %{home: home, secrets: needed_secrets(config), literal_secrets: literal_secrets(config)}}
      end
    rescue
      e ->
        File.rm_rf(incoming)
        {:error, {:restore_failed, Exception.message(e)}}
    after
      File.rm_rf(stage)
    end
  end

  # Copy the unpacked tree into a sibling of `home` (same filesystem, so the later rename is
  # atomic and cheap). `home` is not touched here: if this fails, the old install is intact.
  defp stage_copy(root, incoming) do
    File.rm_rf(incoming)

    case File.cp_r(root, incoming) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, {:restore_failed, "copy to #{path}: #{:file.format_error(reason)}"}}
    end
  end

  # Replace `home` with the fully-copied `incoming` using renames on one filesystem. The old home
  # is moved aside first and only removed once the new one is in place; if the final rename were
  # to fail, the old home is put back rather than lost.
  defp swap_into_place(incoming, home) do
    File.mkdir_p!(Path.dirname(home))
    old = "#{home}.replaced-#{System.unique_integer([:positive])}"
    had_home = File.exists?(home)
    if had_home, do: File.rename!(home, old)

    try do
      File.rename!(incoming, home)
    rescue
      e ->
        if had_home, do: File.rename(old, home)
        reraise e, __STACKTRACE__
    end

    File.rm_rf(old)
    :ok
  end

  ###
  ### staging an extract
  ###

  # Each kept agent's private workspace: companies/<co>/agents/<name> -> agents/<name>.
  defp copy_company_agents(root, company, config) do
    dst_base = Path.join(root, "agents")

    for {handle, _} <- Map.get(config, "agents", %{}) do
      # Handles in the extracted config are already bare (de-scoped), and the source lives under
      # the company on the original install.
      src = Path.join([Config.home(), "companies", company, "agents", handle])

      if File.dir?(src) do
        File.mkdir_p!(dst_base)
        File.cp_r!(src, Path.join(dst_base, handle))
      end
    end
  end

  defp copy_company_shared(root, company) do
    src = Path.join([Config.home(), "companies", company, "shared"])
    if File.dir?(src), do: File.cp_r!(src, Path.join(root, "shared"))
  end

  # The company's usage ledger becomes the root ledger, with each line's `agent` handle
  # de-scoped so the archive's billing history matches its now-bare agents.
  defp copy_usage(root, company) do
    src = Log.scope_dir(company)

    if File.dir?(src) do
      dst = Path.join([root, "data", "usage", "root"])
      File.mkdir_p!(dst)

      for file <- File.ls!(src), String.ends_with?(file, ".jsonl") do
        lines =
          Path.join(src, file)
          |> File.stream!()
          |> Enum.map(&descope_usage_line/1)

        File.write!(Path.join(dst, file), lines)
      end
    end
  end

  defp descope_usage_line(line) do
    case Jason.decode(line) do
      {:ok, %{"agent" => agent} = entry} when is_binary(agent) ->
        Jason.encode!(%{entry | "agent" => Pepe.Company.name_of(agent)}) <> "\n"

      _ ->
        line
    end
  end

  # Plugins and skills are install-wide capability, not tenant data - an agent that used a skill
  # keeps working in the bundle only if they come along.
  defp copy_global_capability(root) do
    for dir <- ~w(plugins skills) do
      src = Path.join(Config.home(), dir)
      if File.dir?(src), do: File.cp_r!(src, Path.join(root, dir))
    end
  end

  ###
  ### tar / untar (system tar, same as `mix pepe backup`)
  ###

  defp tar(output, stage, home_base) do
    case System.cmd("tar", ["-czf", output, "-C", stage, home_base], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {msg, _} -> {:error, {:tar_failed, String.trim(msg)}}
    end
  end

  defp untar(archive, into) do
    case System.cmd("tar", ["-xzf", Path.expand(archive), "-C", into], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {msg, _} -> {:error, {:untar_failed, String.trim(msg)}}
    end
  end

  # The archive holds a single top directory (the home basename); find the one that carries a
  # config.json so restore does not depend on what that basename happens to be. Exactly one is
  # expected - a hand-crafted archive with two would otherwise restore from an arbitrary one.
  defp locate_root(stage) do
    roots =
      stage
      |> File.ls!()
      |> Enum.map(&Path.join(stage, &1))
      |> Enum.filter(&File.regular?(Path.join(&1, "config.json")))

    case roots do
      [root] -> {:ok, root}
      [] -> {:error, :not_a_pepe_archive}
      _ -> {:error, :ambiguous_archive}
    end
  end

  ###
  ### helpers
  ###

  defp populated?(home) do
    case File.ls(home) do
      {:ok, entries} -> entries != []
      _ -> false
    end
  end

  # The env vars the restored install needs to resolve its secrets - `${VAR}` refs plus the
  # vault-opening credentials - read off the config that just landed. Same source of truth as
  # extract, so a round-trip reports the same set.
  defp needed_secrets(config_path) do
    with {:ok, body} <- File.read(config_path),
         {:ok, config} <- Jason.decode(body) do
      Config.provisioning_env(config)
    else
      _ -> []
    end
  end

  # The raw credentials the restored config carries in the clear, so the CLI can tell the
  # operator to rotate/re-authenticate them (they were in the archive, not provisioned fresh).
  defp literal_secrets(config_path) do
    with {:ok, body} <- File.read(config_path),
         {:ok, config} <- Jason.decode(body) do
      Config.literal_secrets(config)
    else
      _ -> []
    end
  end
end
