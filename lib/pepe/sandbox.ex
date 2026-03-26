defmodule Pepe.Sandbox do
  @moduledoc """
  Two layers of protection for the shell/script tools (`bash`, `run_script`).

  ## 1. Guardrails — on by default, zero config, cross-platform

  `guard/1` inspects a shell command and refuses a small set of **catastrophic,
  never-legitimate** operations (wiping the disk, formatting a filesystem, fork
  bombs, powering the host off). It is a thin safety net against accidents and
  obvious prompt-injection, **not** a security boundary: a determined or obfuscated
  command can slip past static inspection. It costs nothing and needs no setup, so
  it runs always.

  ## 2. Isolation — opt-in, strong

  For a real boundary, configure a **sandbox wrapper** (`Pepe.Config.set_sandbox/1`,
  or `mix pepe setup`): a path to an executable that receives the real command and
  runs it isolated however the host allows — Docker/Podman (portable, Linux/macOS/
  Windows), `firejail`/`bwrap` (Linux), `sandbox-exec` (macOS). Pepe passes the
  agent's working directory in `PEPE_SANDBOX_CWD`. Example wrappers ship in
  `examples/sandbox/`. Unset (the default) = the command runs directly on the host,
  and the permission gate (a human approving each call) is the protection.

  There is no zero-config, cross-platform *true* sandbox: every real one needs an OS
  feature or an external tool. So the honest defaults are the permission gate plus
  these guardrails; opt into a wrapper for isolation.
  """

  alias Pepe.Config

  # Patterns that are catastrophic and never part of a legitimate agent task. Kept
  # deliberately narrow to avoid blocking real work (installing deps, querying a DB).
  @blocked [
    {~r{\brm\s+-[a-zA-Z]*[rf][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/(\s|$|\*)|~(/|\s|$)|\$\{?HOME\}?|/(etc|usr|bin|sbin|lib|lib64|boot|var|opt|root|home|dev|System|Library|Applications)(/|\s|$))},
     "recursive delete of a system path, / ~ or $HOME"},
    {~r{\bmkfs(\.\w+)?\b}, "formatting a filesystem"},
    {~r{\bdd\b[^\n]*\bof=/dev/(sd|disk|nvme|hd|xvd|mmcblk)}, "writing raw to a disk device"},
    {~r{>\s*/dev/(sd|disk|nvme|hd|xvd|mmcblk)}, "overwriting a disk device"},
    {~r{:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:}, "fork bomb"},
    {~r{\b(shutdown|reboot|halt|poweroff|init\s+0)\b}, "powering off or rebooting the host"}
  ]

  @doc "Refuse a catastrophic command. Returns `:ok` or `{:block, reason}`."
  @spec guard(String.t()) :: :ok | {:block, String.t()}
  def guard(command) when is_binary(command) do
    Enum.find_value(@blocked, :ok, fn {re, why} ->
      if Regex.match?(re, command), do: {:block, why}
    end)
  end

  def guard(_), do: :ok

  @doc "Whether a strong-isolation wrapper is configured."
  def isolated?, do: not is_nil(Config.sandbox())

  @docker ~S"""
  #!/usr/bin/env sh
  # Pepe sandbox wrapper: run the agent's command inside an ephemeral container.
  # Only the agent's working dir is mounted, so the rest of the host FS is invisible.
  # Portable: Linux, macOS and Windows wherever Docker/Podman is installed.
  # Tune: PEPE_SANDBOX_IMAGE, PEPE_SANDBOX_NET (bridge|none), PEPE_SANDBOX_MEM,
  # PEPE_SANDBOX_CPUS, PEPE_SANDBOX_RUNTIME (docker|podman).
  set -eu
  IMAGE="${PEPE_SANDBOX_IMAGE:-python:3.12-slim}"
  exec "${PEPE_SANDBOX_RUNTIME:-docker}" run --rm \
    --network "${PEPE_SANDBOX_NET:-bridge}" \
    --memory "${PEPE_SANDBOX_MEM:-512m}" --cpus "${PEPE_SANDBOX_CPUS:-1}" \
    --pids-limit 256 \
    -v "$PEPE_SANDBOX_CWD:$PEPE_SANDBOX_CWD" -w "$PEPE_SANDBOX_CWD" \
    "$IMAGE" "$@"
  """

  @firejail ~S"""
  #!/usr/bin/env sh
  # Pepe sandbox wrapper for Linux using firejail (namespaces, lightweight).
  # Confines filesystem writes to the agent's workspace; keeps networking.
  set -eu
  exec firejail --quiet \
    --private="$PEPE_SANDBOX_CWD" --whitelist="$PEPE_SANDBOX_CWD" \
    --caps.drop=all --nonewprivs --noroot \
    -- "$@"
  """

  @macos ~S"""
  #!/usr/bin/env sh
  # Pepe sandbox wrapper for macOS using sandbox-exec (Seatbelt). Denies writes
  # outside the workspace and temp dirs. sandbox-exec is deprecated but functional.
  set -eu
  PROFILE="(version 1)
  (allow default)
  (deny file-write*)
  (allow file-write*
    (subpath \"$PEPE_SANDBOX_CWD\")
    (subpath \"/private/tmp\")
    (subpath \"/private/var/folders\"))"
  exec sandbox-exec -p "$PROFILE" "$@"
  """

  @doc "The wrapper script source for a kind (`\"docker\"`/`\"firejail\"`/`\"macos\"`), or nil."
  def wrapper_script("docker"), do: @docker
  def wrapper_script("firejail"), do: @firejail
  def wrapper_script("macos"), do: @macos
  def wrapper_script(_), do: nil

  @doc """
  Write the wrapper of `kind` to `<PEPE_HOME>/sandbox/<kind>.sh` (executable) and
  return its path, so it is self-contained in the operator's home. `{:error, reason}`
  for an unknown kind.
  """
  def install_wrapper(kind) do
    case wrapper_script(kind) do
      nil ->
        {:error, :unknown_wrapper}

      script ->
        path = Path.join([Config.home(), "sandbox", "#{kind}.sh"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, script)
        File.chmod!(path, 0o755)
        {:ok, path}
    end
  end

  @doc """
  Run `program` with `argv` (like `System.cmd/3`), through the configured sandbox
  wrapper when one is set, else directly. Returns `{output, exit_status}`.
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(program, argv, opts \\ []) do
    case Config.sandbox() do
      nil ->
        System.cmd(program, argv, opts)

      wrapper ->
        cwd = opts[:cd] || File.cwd!()
        env = [{"PEPE_SANDBOX_CWD", cwd} | opts[:env] || []]
        System.cmd(wrapper, [program | argv], Keyword.put(opts, :env, env))
    end
  end
end
