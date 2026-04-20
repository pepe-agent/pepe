defmodule Pepe.ServiceInstall do
  @moduledoc """
  Installs `pepe serve` as a persistent background service so it survives
  logout and reboot, and restarts itself if it crashes: a systemd `--user`
  unit on Linux, a launchd LaunchAgent on macOS. Mirrors the pattern most
  agent-runtime CLIs use for their gateway/server process.

  Only works from the packaged `pepe` binary - it needs a stable absolute
  path to point the service at, which a `mix pepe` invocation doesn't have.
  """

  alias Pepe.Config

  @macos_label "com.pepe-agent.serve"
  @linux_unit "pepe.service"

  @spec install(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install(opts \\ []) do
    with {:ok, bin} <- bin_path() do
      case os() do
        :macos -> install_macos(bin, opts)
        :linux -> install_linux(bin, opts)
        :unsupported -> {:error, unsupported_message()}
      end
    end
  end

  @spec uninstall() :: {:ok, String.t()} | {:error, String.t()}
  def uninstall do
    case os() do
      :macos -> uninstall_macos()
      :linux -> uninstall_linux()
      :unsupported -> {:error, unsupported_message()}
    end
  end

  @spec status() :: {:ok, String.t()} | {:error, String.t()}
  def status do
    case os() do
      :macos -> status_macos()
      :linux -> status_linux()
      :unsupported -> {:error, unsupported_message()}
    end
  end

  # ---- macOS (launchd) ---------------------------------------------------------------

  defp install_macos(bin, opts) do
    path = macos_plist_path()
    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(macos_log_dir())
    File.write!(path, macos_plist(bin, opts))

    # Reinstalling: tear down the old registration first (ignore "not loaded" errors).
    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@macos_label}"], stderr_to_stdout: true)

    case System.cmd("launchctl", ["bootstrap", "gui/#{uid()}", path], stderr_to_stdout: true) do
      {_, 0} ->
        System.cmd("launchctl", ["enable", "gui/#{uid()}/#{@macos_label}"], stderr_to_stdout: true)

        {:ok,
         "installed and started - survives logout/reboot, restarts on crash\n" <>
           "  plist: #{path}\n  logs:  #{macos_log_path()}" <> secrets_note()}

      {msg, _} ->
        {:error, "launchctl bootstrap failed: #{String.trim(msg)}"}
    end
  end

  defp uninstall_macos do
    path = macos_plist_path()
    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@macos_label}"], stderr_to_stdout: true)
    File.rm(path)
    {:ok, "stopped and removed (#{path})"}
  end

  defp status_macos do
    case System.cmd("launchctl", ["print", "gui/#{uid()}/#{@macos_label}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, "installed and registered with launchd\n\n#{out}"}
      {_, _} -> {:ok, "not installed (run `pepe serve install`)"}
    end
  end

  defp macos_plist_path, do: Path.expand("~/Library/LaunchAgents/#{@macos_label}.plist")
  defp macos_log_dir, do: Path.expand("~/Library/Logs/pepe")
  defp macos_log_path, do: Path.join(macos_log_dir(), "serve.log")

  @doc false
  def macos_plist(bin, opts) do
    args = ["<string>#{xml_escape(bin)}</string>", "<string>serve</string>" | port_args(opts)]

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@macos_label}</string>
      <key>ProgramArguments</key>
      <array>
        #{Enum.join(args, "\n    ")}
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardOutPath</key>
      <string>#{xml_escape(macos_log_path())}</string>
      <key>StandardErrorPath</key>
      <string>#{xml_escape(macos_log_path())}</string>
      #{environment_plist()}
    </dict>
    </plist>
    """
  end

  defp environment_plist do
    case env_pairs() do
      [] ->
        ""

      pairs ->
        entries =
          Enum.map_join(pairs, "\n    ", fn {k, v} ->
            "<key>#{xml_escape(k)}</key>\n    <string>#{xml_escape(v)}</string>"
          end)

        "<key>EnvironmentVariables</key>\n  <dict>\n    #{entries}\n  </dict>"
    end
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ---- Linux (systemd --user) ---------------------------------------------------------

  defp install_linux(bin, opts) do
    path = linux_unit_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, linux_unit(bin, opts))

    with {_, 0} <- System.cmd("systemctl", ["--user", "daemon-reload"], stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("systemctl", ["--user", "enable", "--now", @linux_unit], stderr_to_stdout: true) do
      maybe_enable_linger()

      {:ok,
       "installed and started - restarts on crash\n" <>
         "  unit: #{path}\n" <>
         "  logs: journalctl --user -u #{@linux_unit} -f" <> secrets_note()}
    else
      {msg, _} -> {:error, "systemctl failed: #{String.trim(msg)}"}
    end
  end

  defp uninstall_linux do
    System.cmd("systemctl", ["--user", "disable", "--now", @linux_unit], stderr_to_stdout: true)
    File.rm(linux_unit_path())
    System.cmd("systemctl", ["--user", "daemon-reload"], stderr_to_stdout: true)
    {:ok, "stopped and removed (#{linux_unit_path()})"}
  end

  defp status_linux do
    case System.cmd("systemctl", ["--user", "status", @linux_unit], stderr_to_stdout: true) do
      {out, code} when code in [0, 3] -> {:ok, out}
      _ -> {:ok, "not installed (run `pepe serve install`)"}
    end
  end

  defp linux_unit_path, do: Path.expand("~/.config/systemd/user/#{@linux_unit}")

  @doc false
  def linux_unit(bin, opts) do
    exec = Enum.join([bin, "serve" | port_flags(opts)], " ")

    env_block =
      case Enum.map(env_pairs(), fn {k, v} -> "Environment=#{k}=#{v}" end) do
        [] -> ""
        lines -> "\n" <> Enum.join(lines, "\n")
      end

    """
    [Unit]
    Description=Pepe - AI agent runtime (serve)
    After=network-online.target
    Wants=network-online.target
    StartLimitBurst=5
    StartLimitIntervalSec=60

    [Service]
    ExecStart=#{exec}
    Restart=always
    RestartSec=5#{env_block}

    [Install]
    WantedBy=default.target
    """
  end

  # systemd --user services only run while the user is logged in unless lingering is
  # enabled; try it unprivileged first (works on some distros), else just tell the user.
  defp maybe_enable_linger do
    user = System.get_env("USER") || System.get_env("LOGNAME") || ""

    case System.cmd("loginctl", ["enable-linger", user], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :skip
    end
  end

  # ---- shared --------------------------------------------------------------------------

  defp port_args(opts), do: opts |> port_flags() |> Enum.map(&"<string>#{&1}</string>")
  defp port_flags(opts), do: if(opts[:port], do: ["--port", to_string(opts[:port])], else: [])

  defp env_pairs do
    for {name, value} <- [{"PEPE_HOME", System.get_env("PEPE_HOME")}, {"PEPE_CONFIG", System.get_env("PEPE_CONFIG")}],
        is_binary(value),
        do: {name, value}
  end

  # ${ENV_VAR} secrets resolve from the process environment at read time - a launchd/
  # systemd service starts with a minimal env, so any secret referenced in config.json
  # needs to be added to the service definition by hand, or it'll come up unset.
  defp secrets_note do
    vars =
      case File.read(Path.join(Config.home(), "config.json")) do
        {:ok, body} ->
          ~r/\$\{([A-Z0-9_]+)\}/ |> Regex.scan(body) |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.sort()

        _ ->
          []
      end

    if vars == [] do
      ""
    else
      "\n\nYour config references ${ENV_VAR} secrets: #{Enum.join(vars, ", ")}.\n" <>
        "The service starts with a minimal environment - add these to it by hand\n" <>
        "(the generated file has a spot for them) or the agent will see them as unset."
    end
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _ -> :unsupported
    end
  end

  defp unsupported_message do
    "no service-install support for this OS yet (macOS and Linux only) - " <>
      "run `pepe serve` directly, or manage it with your own process supervisor"
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

  defp bin_path do
    case Burrito.Util.Args.get_bin_path() do
      :not_in_burrito ->
        {:error, "serve install only works from the installed pepe binary, not `mix pepe`"}

      path ->
        {:ok, path}
    end
  end
end
