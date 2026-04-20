defmodule Pepe.Tunnel do
  @moduledoc """
  Expose the local server to the internet through a Cloudflare **quick tunnel**, so you
  can reach the dashboard or API from anywhere without opening a port or configuring a
  domain. No Cloudflare account is needed: `cloudflared tunnel --url ...` mints an
  ephemeral `https://<something>.trycloudflare.com` address for the lifetime of the
  process.

  The tunnel is a child OS process (a `Port`) linked to the caller, so it dies with the
  server. It runs `cloudflared`, which must be installed (`brew install cloudflared`,
  or see the Cloudflare docs).

  Security: a tunneled request reaches the server through a proxy, so `PepeWeb.NetworkGuard`
  treats it as public and the dashboard stays fail-closed until a password is set. Set one
  (`mix pepe dashboard password ...`) before relying on a tunnel.
  """
  require Logger

  @url_re ~r{https://[a-z0-9-]+\.trycloudflare\.com}

  @doc "Is the `cloudflared` binary available on PATH?"
  def available?, do: not is_nil(System.find_executable("cloudflared"))

  @doc """
  Open a quick tunnel to `http://localhost:port`. Calls `on_url.(url)` once when the public
  URL appears in cloudflared's output. Returns `{:ok, port}` or `{:error, :cloudflared_not_found}`.
  """
  def open(port, on_url) when is_integer(port) and is_function(on_url, 1) do
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
              # --loglevel info: guard against a build that defaults to a quieter level
              # when stdout isn't a TTY (as it never is through a Port).
              args: ["tunnel", "--no-autoupdate", "--loglevel", "info", "--url", "http://localhost:#{port}"]
            ])

          send(parent, {:pepe_tunnel_port, os_port})
          watch(os_port, port, on_url)
        end)

        receive do
          {:pepe_tunnel_port, os_port} -> {:ok, os_port}
        after
          5_000 -> {:error, :cloudflared_start_timeout}
        end
    end
  end

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

  defp watch(os_port, net_port, on_url, buffer \\ "", announced? \\ false, warned? \\ false) do
    receive do
      {^os_port, {:data, data}} ->
        buffer = truncate(buffer <> data, @max_buffer)
        url = extract_url(buffer)

        announced? =
          if not announced? and url do
            on_url.(url)
            true
          else
            announced?
          end

        watch(os_port, net_port, on_url, buffer, announced?, warned?)

      {^os_port, {:exit_status, status}} ->
        Logger.warning("[tunnel] cloudflared exited (status #{status})")
    after
      @url_timeout_ms ->
        if not announced? and not warned? do
          Logger.warning(
            "[tunnel] no URL from cloudflared after #{div(@url_timeout_ms, 1000)}s - " <>
              "it may still be starting, or its output isn't reaching this process; " <>
              "try `cloudflared tunnel --url http://localhost:#{net_port}` directly to check"
          )
        end

        watch(os_port, net_port, on_url, buffer, announced?, true)
    end
  end

  # Byte-safe truncation - raw process output isn't guaranteed valid UTF-8 (ANSI
  # escapes, box-drawing bytes, ...), so String.slice/3 would be a crash risk here.
  @doc false
  def truncate(bin, max) when byte_size(bin) <= max, do: bin
  def truncate(bin, max), do: :binary.part(bin, byte_size(bin) - max, max)
end
