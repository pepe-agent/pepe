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
        p =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["tunnel", "--no-autoupdate", "--url", "http://localhost:#{port}"]
          ])

        spawn_link(fn -> watch(p, on_url, false) end)
        {:ok, p}
    end
  end

  @doc "Extract the `trycloudflare.com` URL from a chunk of cloudflared output, or nil."
  def extract_url(data) when is_binary(data) do
    case Regex.run(@url_re, data) do
      [url] -> url
      _ -> nil
    end
  end

  defp watch(port, on_url, announced?) do
    receive do
      {^port, {:data, data}} ->
        url = extract_url(data)

        announced? =
          if not announced? and url do
            on_url.(url)
            true
          else
            announced?
          end

        watch(port, on_url, announced?)

      {^port, {:exit_status, status}} ->
        Logger.warning("[tunnel] cloudflared exited (status #{status})")
    end
  end
end
