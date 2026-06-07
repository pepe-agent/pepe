defmodule Pepe.Sandbox do
  @moduledoc """
  Two layers of protection for the shell/script tools (`bash`, `run_script`).

  ## 1. Guardrails: on by default, zero config, cross-platform

  `guard/1` inspects a shell command and refuses a small set of **catastrophic,
  never-legitimate** operations (wiping the disk, formatting a filesystem, fork
  bombs, powering the host off). It is a thin safety net against accidents and
  obvious prompt-injection, **not** a security boundary: a determined or obfuscated
  command can slip past static inspection. It costs nothing and needs no setup, so
  it runs always.

  ## 2. Isolation: opt-in, strong

  For a real boundary, configure a **sandbox wrapper** (`Pepe.Config.set_sandbox/1`,
  or `mix pepe setup`): a path to an executable that receives the real command and
  runs it isolated however the host allows: Docker/Podman (portable, Linux/macOS/
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
  #
  # A function, not a module attribute: OTP 28 changed compiled regexes to hold a
  # NIF resource reference internally, which can no longer be "escaped" into a
  # module attribute (baked into the compiled .beam as a literal) - only a small,
  # fixed set of term shapes can be. Building the list at call time compiles these
  # same 6 patterns fresh per call instead of once at compile time, which is
  # negligible next to actually running the shell command being guarded.
  defp blocked_patterns do
    [
      {~r{\brm\s+-[a-zA-Z]*[rf][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/(\s|$|\*)|~(/|\s|$)|\$\{?HOME\}?|/(etc|usr|bin|sbin|lib|lib64|boot|var|opt|root|home|dev|System|Library|Applications)(/|\s|$))},
       "recursive delete of a system path, / ~ or $HOME"},
      {~r{\bmkfs(\.\w+)?\b}, "formatting a filesystem"},
      {~r{\bdd\b[^\n]*\bof=/dev/(sd|disk|nvme|hd|xvd|mmcblk)}, "writing raw to a disk device"},
      {~r{>\s*/dev/(sd|disk|nvme|hd|xvd|mmcblk)}, "overwriting a disk device"},
      {~r{:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:}, "fork bomb"},
      {~r{\b(shutdown|reboot|halt|poweroff|init\s+0)\b}, "powering off or rebooting the host"}
    ]
  end

  @doc "Refuse a catastrophic command. Returns `:ok` or `{:block, reason}`."
  @spec guard(String.t()) :: :ok | {:block, String.t()}
  def guard(command) when is_binary(command) do
    Enum.find_value(blocked_patterns(), :ok, fn {re, why} ->
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

  The child does **not** inherit Pepe's secrets. See `scrubbed_env/1`.
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(program, argv, opts \\ []) do
    opts = Keyword.put(opts, :env, scrubbed_env(opts[:env] || []))

    case Config.sandbox() do
      nil ->
        System.cmd(program, argv, opts)

      wrapper ->
        cwd = opts[:cd] || File.cwd!()
        env = [{"PEPE_SANDBOX_CWD", cwd} | opts[:env]]
        System.cmd(wrapper, [program | argv], Keyword.put(opts, :env, env))
    end
  end

  @doc """
  The environment to hand a command the agent chose: everything Pepe has, minus its secrets.

  `System.cmd/3` gives a child the parent's whole environment, which meant the agent's shell
  inherited Pepe's - and Pepe's environment is where the API keys are. `echo $OPENAI_API_KEY`
  returned the key. So did `env`. The `${ENV_VAR}` scheme kept secrets out of the *config
  file*, which is a real protection against a leaked backup or a careless commit, and did
  nothing at all about the agent, because the secret still had to exist somewhere for Pepe to
  use it, and that somewhere was the process the agent's shell is a child of.

  A variable is dropped when the config refers to it as a secret (every `${VAR}` Pepe reads
  is, by definition, a secret it holds) or when its name says it is one (`GITHUB_TOKEN`,
  `AWS_SECRET_ACCESS_KEY`). What is left is the ordinary environment a command needs to work:
  `PATH`, `HOME`, `LANG`.

  This is not a sandbox, and it does not pretend to be. An agent that can run arbitrary shell
  can still read any file the user can read. What it closes is the cheapest and most likely
  leak by a wide margin - the one a prompt injection reaches with a single word, `env` - and
  it removes the thing that made "the config has no secrets in it" a comfortable half-truth.

  ## The deliberate exception: letting the agent open a vault itself

  Sometimes the task *is* the credential - "find the Postgres login in 1Password and use it".
  For that the agent needs a vault CLI (`op`) and the token that unlocks it, in its own shell.
  `secrets.expose_env` (`Config.expose_env/0`) is the opt-in: the operator names the vault
  token there and it survives the scrub, so the agent can run `op` conversationally, with no
  per-secret wiring. It is off by default, and the safe pattern is a narrowly-scoped provider
  token whose blast radius is only what it can reach. See the `vaults` skill.
  """
  @spec scrubbed_env(keyword() | [{String.t(), String.t()}]) :: [{String.t(), String.t() | nil}]
  def scrubbed_env(extra \\ []) do
    # `${VAR}` refs plus the vault-opening credentials. The latter are named to be handed to a
    # resolver so it can open the vault (`OP_SERVICE_ACCOUNT_TOKEN`, `VAULT_TOKEN`, a custom
    # one); they unlock every secret Pepe holds, so the agent's own shell must never inherit
    # them, and a name like `MY_VAULT_CRED` would slip past the by-the-name check on its own.
    referenced = MapSet.new(secret_env_names() ++ vault_env())

    # ...except the ones the operator deliberately allowed the agent to keep, so it can open a
    # vault itself (`secrets.expose_env`). Off by default; see the moduledoc.
    exposed = MapSet.new(Config.expose_env())

    # `System.cmd/3` *merges* `:env` into the parent's environment, it does not replace it, so
    # listing what to keep would keep everything. A variable is removed by naming it with a
    # nil value. Getting this backwards is exactly the kind of mistake that leaves a security
    # control looking like it works, which is why the tests run a real `env`.
    dropped =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn name ->
        not MapSet.member?(exposed, name) and
          (MapSet.member?(referenced, name) or Pepe.Secrets.secret_key?(name))
      end)
      |> Enum.map(&{&1, nil})

    dropped ++ Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  # Every ${VAR} the config points at. Pepe reads these to authenticate; that is what makes
  # them secrets, whatever they happen to be called.
  defp secret_env_names do
    Config.load()
    |> collect_refs()
    |> Enum.uniq()
  rescue
    # A broken or missing config must not hand the agent the environment by default.
    _ -> []
  end

  # The vault-resolver credentials the config names. Read separately from the `${VAR}` refs
  # because a vault entry is `exec:…` or `file:…`, not an interpolation, so `collect_refs`
  # never sees these.
  defp vault_env do
    Config.vault_env()
  rescue
    _ -> []
  end

  defp collect_refs(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_refs/1)

  defp collect_refs(value) when is_list(value), do: Enum.flat_map(value, &collect_refs/1)

  defp collect_refs(value) when is_binary(value) do
    ~r/\$\{([A-Z0-9_]+)\}/
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
  end

  defp collect_refs(_value), do: []
end
