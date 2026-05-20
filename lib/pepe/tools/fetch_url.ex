defmodule Pepe.Tools.FetchUrl do
  @moduledoc "Fetch a URL over HTTP(S) and return the response body."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "fetch_url"

  @impl true
  def spec do
    function("fetch_url", "Perform an HTTP GET and return the (text) response body.", %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to fetch."}
      },
      "required" => ["url"]
    })
  end

  # Waits on a network, which is exactly what makes running these together worth it.
  @impl true
  def concurrent?, do: true

  # How many redirects to follow before giving up.
  @max_redirects 5

  @impl true
  def run(%{"url" => url}, _ctx), do: fetch(url, 0)

  def run(_, _), do: {:error, "missing 'url'"}

  # Redirects are followed by hand, not by Req, because Req's automatic redirect would jump to a
  # `Location` no one validated - the classic SSRF: a public URL that 302s to
  # `http://169.254.169.254/…` (cloud metadata). Every hop, including the redirect targets, is
  # re-checked against `Pepe.Net.internal?` here, so an internal address is refused wherever in
  # the chain it appears.
  defp fetch(_url, hops) when hops > @max_redirects, do: {:error, "too many redirects"}

  defp fetch(url, hops) do
    with {:ok, host} <- parse_host(url),
         :ok <- check_host(host) do
      case Req.get(url, receive_timeout: 30_000, retry: :transient, redirect: false) do
        {:ok, resp} -> handle_response(resp, url, hops)
        {:error, reason} -> {:error, "request failed: #{inspect(reason)}"}
      end
    end
  end

  # A 3xx is followed by re-entering `fetch/2` on the (validated) target; anything else is the
  # body. Splitting this out of `fetch/2` keeps each function's nesting shallow.
  defp handle_response(%{status: status} = resp, url, hops) when status in 300..399 do
    case redirect_target(resp, url) do
      {:ok, next} -> fetch(next, hops + 1)
      :none -> {:ok, format(resp)}
    end
  end

  defp handle_response(resp, _url, _hops), do: {:ok, format(resp)}

  defp redirect_target(%{headers: headers}, base) do
    case headers["location"] do
      [loc | _] when is_binary(loc) and loc != "" -> {:ok, base |> URI.merge(loc) |> URI.to_string()}
      _ -> :none
    end
  end

  defp format(%{status: status, body: body}), do: "status=#{status}\n#{truncate(stringify(body))}"

  defp parse_host(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, host}

      {:ok, _} ->
        {:error, "only http/https URLs with a host are allowed"}

      {:error, _} ->
        {:error, "invalid URL"}
    end
  end

  # Resolves every address the host could hit (not just the first) and rejects if
  # any is internal - blocks direct internal IPs and hostnames that resolve there.
  # Doesn't pin the resolved IP for the actual request below, so a DNS answer that
  # flips between this check and Req's own resolution (classic rebinding) isn't
  # fully closed - acceptable for the LLM-fetches-a-URL threat model here.
  defp check_host(host) do
    case Pepe.Net.parse_address(host) do
      {:ok, ip} -> reject_if_internal(ip)
      :error -> host |> resolve_all() |> reject_any_internal()
    end
  end

  defp resolve_all(host) do
    charlist = String.to_charlist(host)
    v4 = gethostbyname(charlist, :inet)
    v6 = gethostbyname(charlist, :inet6)

    case v4 ++ v6 do
      [] -> {:error, "could not resolve host"}
      ips -> {:ok, ips}
    end
  end

  defp gethostbyname(charlist, family) do
    # :inet.gethostbyname/2 returns the :hostent record as a plain tuple, not a
    # map - {:h_addr_list: [...]} never matches it, which silently made every
    # hostname resolve to [] (and every hostname-based fetch fail closed as
    # "could not resolve host") instead of actually validating the real IPs.
    case :inet.gethostbyname(charlist, family) do
      {:ok, {:hostent, _name, _aliases, _addrtype, _length, addrs}} -> addrs
      {:error, _} -> []
    end
  end

  defp reject_any_internal({:error, reason}), do: {:error, reason}

  defp reject_any_internal({:ok, ips}) do
    if Enum.any?(ips, &Pepe.Net.internal?/1) do
      {:error, "refusing to fetch an internal/private address"}
    else
      :ok
    end
  end

  defp reject_if_internal(ip) do
    if Pepe.Net.internal?(ip), do: {:error, "refusing to fetch an internal/private address"}, else: :ok
  end

  defp stringify(body) when is_binary(body), do: body
  defp stringify(body), do: inspect(body)

  defp truncate(text, max \\ 30_000) do
    if byte_size(text) > max, do: binary_part(text, 0, max) <> "\n...(truncated)", else: text
  end
end
