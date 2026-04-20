defmodule PepeWeb.RemoteClient do
  @moduledoc """
  Resolves the real client of a request for the dashboard defenses, honoring a
  configured trusted-proxy allowlist. Without trusted proxies, any `X-Forwarded-*`
  header is ignored (and disqualifies loopback trust) - the safe default. With them,
  the client IP is taken from the `X-Forwarded-For` chain (rightmost address that
  isn't itself a trusted proxy), so a reverse proxy that terminates TLS still yields
  the true peer for the loopback-vs-remote decision and the login rate-limit.
  """
  import Plug.Conn, only: [get_req_header: 2]

  alias Pepe.Config
  alias Pepe.Net

  @forward_headers ["x-forwarded-for", "x-real-ip", "forwarded"]

  @doc "Does the request carry any proxy-forwarding header?"
  def forwarded?(conn), do: Enum.any?(@forward_headers, &(get_req_header(conn, &1) != []))

  @doc "The effective client IP tuple (peer, or the real client behind a trusted proxy)."
  def ip(conn) do
    proxies = Config.dashboard_trusted_proxies()

    if via_trusted_proxy?(conn, proxies) do
      forwarded_client(conn, proxies) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  @doc """
  A genuine local operator: a loopback client with no proxy in front (or reached
  through a *trusted* proxy from a loopback origin). Anything else is treated as
  remote and must authenticate.
  """
  def local_direct?(conn) do
    proxies = Config.dashboard_trusted_proxies()

    if forwarded?(conn) and not via_trusted_proxy?(conn, proxies) do
      false
    else
      Net.loopback?(ip(conn))
    end
  end

  defp via_trusted_proxy?(conn, proxies) do
    proxies != [] and Net.trusted?(conn.remote_ip, proxies)
  end

  # Rightmost X-Forwarded-For entry that isn't itself a trusted proxy = the real client.
  defp forwarded_client(conn, proxies) do
    case get_req_header(conn, "x-forwarded-for") do
      [xff | _] ->
        xff
        |> String.split(",")
        |> Enum.reverse()
        |> Enum.find_value(&real_client(&1, proxies))

      [] ->
        nil
    end
  end

  defp real_client(part, proxies) do
    case Net.parse_address(part) do
      {:ok, tuple} -> if Net.trusted?(tuple, proxies), do: false, else: tuple
      :error -> false
    end
  end
end
