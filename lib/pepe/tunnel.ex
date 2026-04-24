defmodule Pepe.Tunnel do
  @moduledoc """
  Expose the local server to the internet through Cloudflare, so you can reach the
  dashboard or API from anywhere without opening a port. Three modes, all driven by the
  `cloudflared` binary (`brew install cloudflared`, or see the Cloudflare docs):

    * **Quick tunnel** (default) - no account needed. `cloudflared tunnel --url ...` mints
      an ephemeral, *random* `https://<something>.trycloudflare.com` address for the
      lifetime of the process. You can't choose or keep the name; it changes every run.

    * **Named tunnel by token** (`token:` option) - a stable URL *you* choose. Create a
      tunnel and its public hostname once in the Cloudflare Zero Trust dashboard, point its
      service at `http://localhost:<port>`, copy the connector token, and run
      `cloudflared tunnel run --token <TOKEN>`. Fully headless (no browser login on the
      machine) - the best fit for a server. The hostname lives in the dashboard, so pass
      `hostname:` too if you want the URL printed at startup.

    * **Named tunnel by login** (`hostname:` option) - a stable URL on a domain you own on
      Cloudflare, after a one-time `cloudflared tunnel login` (stores a `cert.pem`). Then
      `cloudflared tunnel --hostname pepe.example.com --url ...` creates/uses a tunnel,
      points the hostname's DNS at it, and serves there.

  The tunnel is a child OS process (a `Port`) linked to the caller, so it dies with the
  server.

  Security: a tunneled request reaches the server through a proxy, so `PepeWeb.NetworkGuard`
  treats it as public and the dashboard stays fail-closed until a password is set. Set one
  (`mix pepe dashboard password ...`) before relying on a tunnel.
  """
  require Logger

  @url_re ~r{https://[a-z0-9-]+\.trycloudflare\.com}

  # cloudflared log lines that mean a tunnel's edge connection is live. For a named
  # tunnel that's when the chosen hostname becomes reachable. Wording has drifted across
  # versions, so match a couple of variants rather than one exact string.
  @ready_re ~r/(Registered tunnel connection|Connection\s+[0-9a-f-]+\s+registered)/i

  @doc "Is the `cloudflared` binary available on PATH?"
  def available?, do: not is_nil(System.find_executable("cloudflared"))

  @doc """
  Open a tunnel to `http://localhost:port`. Calls `on_url.(url_or_status)` once the tunnel
  is live: with the public URL string when it's known, or the atom `:connected` for a
  token tunnel whose hostname lives in the dashboard. Options:

    * `:token` - a Cloudflare tunnel connector token (named tunnel, headless).
    * `:hostname` - a hostname on a domain you own on Cloudflare. With `:token` it's used
      only to print the URL; without it, opens a login/cert.pem named tunnel.

  With neither, opens a quick tunnel with a random `trycloudflare.com` URL. Returns
  `{:ok, port}` or `{:error, :cloudflared_not_found}`.
  """
  def open(port, on_url, opts \\ []) when is_integer(port) and is_function(on_url, 1) do
    token = blank_to_nil(opts[:token])
    hostname = blank_to_nil(opts[:hostname])

    case System.find_executable("cloudflared") do
      nil ->
        {:error, :cloudflared_not_found}

      bin ->
        parent = self()

        # A Port only ever delivers messages to the process that opened it - opening
        # it here and watching it from a separately spawned process (the original bug)
        # means the watcher's `receive` never matches anything, forever. Open and watch
        # in the same (spawned, linked) process instead, and hand the port back via a
        # message so the public API keeps returning {:ok, port}.
        spawn_link(fn ->
          os_port =
            Port.open({:spawn_executable, bin}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: cloudflared_args(port, token, hostname)
            ])

          send(parent, {:pepe_tunnel_port, os_port})
          watch(os_port, port, on_url, detector(token, hostname), {token, hostname}, "", false, false)
        end)

        receive do
          {:pepe_tunnel_port, os_port} -> {:ok, os_port}
        after
          5_000 -> {:error, :cloudflared_start_timeout}
        end
    end
  end

  # --loglevel info: guard against a build that defaults to a quieter level when stdout
  # isn't a TTY (as it never is through a Port).
  @base_args ["tunnel", "--no-autoupdate", "--loglevel", "info"]

  # Token wins for the actual connection (routing lives in the dashboard); a hostname
  # passed alongside it is only for display. Login mode binds --hostname to a local --url.
  @doc false
  def cloudflared_args(port, token, hostname) do
    cond do
      token -> @base_args ++ ["run", "--token", token]
      hostname -> @base_args ++ ["--hostname", hostname, "--url", "http://localhost:#{port}"]
      true -> @base_args ++ ["--url", "http://localhost:#{port}"]
    end
  end

  # Quick tunnel: the URL is announced in cloudflared's output, so pull it from there.
  # Named tunnel: we already know the URL (https://<host>), or - for a token tunnel with
  # no hostname given - only that it's up. Either way, wait for the edge connection to
  # register before announcing, so we never advertise a dead address.
  defp detector(_token, hostname) when is_binary(hostname) do
    fn buffer -> if Regex.match?(@ready_re, buffer), do: "https://#{hostname}", else: nil end
  end

  defp detector(token, nil) when is_binary(token) do
    fn buffer -> if Regex.match?(@ready_re, buffer), do: :connected, else: nil end
  end

  defp detector(nil, nil), do: &extract_url/1

  @doc "Extract the `trycloudflare.com` URL from a chunk of cloudflared output, or nil."
  def extract_url(data) when is_binary(data) do
    case Regex.run(@url_re, data) do
      [url] -> url
      _ -> nil
    end
  end

  # Bound how much unmatched output we hold on to per line - a truncated line just
  # means a slightly wider window is needed, not a leak.
  @max_buffer 8192
  # If cloudflared hasn't announced a URL by then, something's off (usually its
  # output never reaching this port) - say so instead of waiting forever in silence.
  @url_timeout_ms 30_000

  defp watch(os_port, net_port, on_url, detect, mode, buffer, announced?, warned?) do
    receive do
      {^os_port, {:data, data}} ->
        buffer = truncate(buffer <> data, @max_buffer)
        found = detect.(buffer)

        announced? =
          if not announced? and found do
            on_url.(found)
            true
          else
            announced?
          end

        watch(os_port, net_port, on_url, detect, mode, buffer, announced?, warned?)

      {^os_port, {:exit_status, status}} ->
        Logger.warning("[tunnel] cloudflared exited (status #{status})")
    after
      @url_timeout_ms ->
        if not announced? and not warned? do
          Logger.warning(timeout_hint(mode, net_port))
        end

        watch(os_port, net_port, on_url, detect, mode, buffer, announced?, true)
    end
  end

  defp timeout_hint({token, _hostname}, _net_port) when is_binary(token) do
    "[tunnel] the token tunnel hasn't connected after #{div(@url_timeout_ms, 1000)}s - " <>
      "check the token is valid and its public hostname's service points at this server " <>
      "in the Cloudflare Zero Trust dashboard"
  end

  defp timeout_hint({_token, hostname}, _net_port) when is_binary(hostname) do
    "[tunnel] the named tunnel for #{hostname} hasn't connected after " <>
      "#{div(@url_timeout_ms, 1000)}s - make sure the domain is on Cloudflare and you've run " <>
      "`cloudflared tunnel login` once (it stores a cert.pem for the zone)"
  end

  defp timeout_hint({nil, nil}, net_port) do
    "[tunnel] no URL from cloudflared after #{div(@url_timeout_ms, 1000)}s - " <>
      "it may still be starting, or its output isn't reaching this process; " <>
      "try `cloudflared tunnel --url http://localhost:#{net_port}` directly to check"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  # Byte-safe truncation - raw process output isn't guaranteed valid UTF-8 (ANSI
  # escapes, box-drawing bytes, ...), so String.slice/3 would be a crash risk here.
  @doc false
  def truncate(bin, max) when byte_size(bin) <= max, do: bin
  def truncate(bin, max), do: :binary.part(bin, byte_size(bin) - max, max)
end
