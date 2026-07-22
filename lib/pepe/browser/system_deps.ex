defmodule Pepe.Browser.SystemDeps do
  @moduledoc """
  Detects the host's Linux package manager and installs a real browser through it,
  for a local (non-Docker) install `Pepe.Browser.Fetcher`'s own download might not be
  able to launch on (a minimal or headless host, missing shared libraries the official
  Docker image bakes in but a bare install can't guarantee).

  Installs full Chromium, not a hand-picked list of its shared libraries the way the
  Dockerfile does - the Dockerfile's split (libraries only, browser binary downloaded
  separately by Fetcher) is worth it there because it's a single image published to
  everyone; a one-time install on someone's own machine doesn't carry that cost, and
  every mainstream distro's own `chromium` package already declares the right runtime
  dependencies for itself - no hand-maintained, hard-to-verify library list needed, and
  once it's installed, Fetcher finds it on PATH directly and never downloads anything
  on that machine again.

  Runs the real install command (with `sudo` if not already root) rather than just
  printing it - the operator already consented by typing `mix pepe browser install` in
  the first place, so this is no different from running `apt install` themselves;
  `sudo` prompts for a password on its own controlling terminal exactly as it would
  if they'd typed the command directly.
  """

  @candidates [
    {"apt-get", ["apt-get", "install", "-y", "chromium"]},
    {"dnf", ["dnf", "install", "-y", "chromium"]},
    {"yum", ["yum", "install", "-y", "chromium"]},
    {"pacman", ["pacman", "-S", "--noconfirm", "chromium"]},
    {"apk", ["apk", "add", "chromium"]},
    {"zypper", ["zypper", "install", "-y", "chromium"]}
  ]

  @doc "`{manager, [executable | args]}` for the first package manager found on PATH, or `:not_found`."
  @spec detect() :: {String.t(), [String.t()]} | :not_found
  def detect do
    Enum.find_value(@candidates, :not_found, fn {bin, cmd} ->
      if System.find_executable(bin), do: {bin, cmd}
    end)
  end

  @doc "Is the current process already running as root (so the install needs no `sudo` prefix)?"
  @spec root?() :: boolean()
  def root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {"0\n", 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @doc """
  Run the detected install command, streaming its output live (package managers print
  real progress, and `sudo` needs the real terminal for its password prompt either
  way). `:ok | {:error, exit_status}`.
  """
  @spec install([String.t()]) :: :ok | {:error, non_neg_integer()}
  def install([exe | args]) do
    {run_exe, run_args} = if root?(), do: {exe, args}, else: {"sudo", [exe | args]}

    case System.cmd(run_exe, run_args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_collectable, 0} -> :ok
      {_collectable, status} -> {:error, status}
    end
  end
end
