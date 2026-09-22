defmodule Pepe.Webhooks.Media.Download do
  @moduledoc """
  The one way an inbound attachment's bytes are pulled off the network.

  A webhook channel hands over a *handle* (a WhatsApp media id that resolves to a signed
  url, a Discord CDN url), and what sits behind it is written by a stranger. So the
  download is bounded on every axis the payload could otherwise abuse:

    * **Size, while streaming.** The body is counted as it arrives and the transfer is
      cut the moment it passes the cap, instead of buffering an arbitrarily large file
      and checking afterwards. A declared `content-length` over the cap is refused before
      the first byte is read, and a missing or lying one changes nothing, because the
      running total is what decides.
    * **Where it goes.** Redirects are followed by hand, never by the HTTP client, and
      every hop (the first url included) is re-checked: https only, an optional host
      allowlist, and never an internal address (`Pepe.Net.public_host/1`, the check
      `fetch_url` already applies to whatever an agent is told to fetch). A public url
      that answers `302` to `http://169.254.169.254/` therefore ends here.
    * **Who is told the secret.** A bearer token is sent to the origin the download
      started at and dropped on any hop that leaves it, so a redirect cannot carry the
      connection's credential to somewhere else.

  Options: `:bearer`, `:headers`, `:hosts` (a list of allowed hosts, matched exactly or as
  a `.suffix`; `nil` = any public host), `:max_bytes` (default `Pepe.Webhooks.Media.max_bytes/0`),
  `:max_redirects` (default 3), `:timeout` (ms), `:schemes` (default `["https"]`) and
  `:check_host` (a 1-arity function, default `Pepe.Net.public_host/1`; tests inject their own).
  """

  alias Pepe.Webhooks.Media

  @max_redirects 3
  @default_timeout 120_000

  @type reason ::
          :too_large
          | :bad_url
          | :too_many_redirects
          | :internal_address
          | :unresolvable
          | {:http, non_neg_integer()}
          | term()

  @doc "GET `url` under the limits above. `{:ok, bytes}` or `{:error, reason}`."
  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, reason()}
  def get(url, opts \\ []) when is_binary(url) do
    ctx = %{
      max_bytes: Keyword.get(opts, :max_bytes, Media.max_bytes()),
      max_redirects: Keyword.get(opts, :max_redirects, @max_redirects),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      hosts: Keyword.get(opts, :hosts),
      schemes: Keyword.get(opts, :schemes, ["https"]),
      check_host: Keyword.get(opts, :check_host, host_check()),
      bearer: Keyword.get(opts, :bearer),
      headers: Keyword.get(opts, :headers, []),
      origin: origin(url)
    }

    hop(url, 0, ctx)
  end

  # `Application.get_env` so a test environment (no DNS) can swap the resolver out for the
  # whole suite, while a caller that cares can still pass `:check_host` for one call.
  defp host_check do
    case Application.get_env(:pepe, :webhook_media_host_check) do
      fun when is_function(fun, 1) -> fun
      _ -> &Pepe.Net.public_host/1
    end
  end

  defp hop(_url, hops, %{max_redirects: max}) when hops > max, do: {:error, :too_many_redirects}

  defp hop(url, hops, ctx) do
    with {:ok, _host} <- validate(url, ctx) do
      case request(url, ctx) do
        {:ok, %{status: status} = resp} when status in 300..399 -> redirect(resp, url, hops, ctx)
        {:ok, %{status: status} = resp} when status in 200..299 -> body(resp, ctx)
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate(url, ctx) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) and host != "" ->
        with true <- scheme in ctx.schemes || {:error, :bad_url},
             true <- host_allowed?(host, ctx.hosts) || {:error, :bad_url},
             :ok <- ctx.check_host.(host) do
          {:ok, host}
        end

      _ ->
        {:error, :bad_url}
    end
  end

  defp host_allowed?(_host, nil), do: true

  defp host_allowed?(host, hosts) do
    host = String.downcase(host)

    Enum.any?(hosts, fn allowed ->
      allowed = String.downcase(allowed)
      host == allowed or String.ends_with?(host, "." <> allowed)
    end)
  end

  defp request(url, ctx) do
    opts =
      [
        decode_body: false,
        redirect: false,
        retry: false,
        receive_timeout: ctx.timeout,
        headers: ctx.headers,
        into: collector(ctx.max_bytes)
      ]
      |> put_auth(ctx, url)

    Req.get(url, opts)
  end

  # The credential only ever travels to the origin the download began at.
  defp put_auth(opts, %{bearer: token, origin: origin}, url) when is_binary(token) and token != "" do
    if origin(url) == origin, do: Keyword.put(opts, :auth, {:bearer, token}), else: opts
  end

  defp put_auth(opts, _ctx, _host), do: opts

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        {String.downcase(scheme), String.downcase(host), port || default_port(scheme)}

      _ ->
        nil
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_scheme), do: nil

  # Counts bytes as they land and halts the transfer past the cap. A declared length over the
  # cap is refused on the first chunk, before it is kept.
  defp collector(max) do
    fn {:data, data}, {req, resp} ->
      {seen, chunks} = Req.Response.get_private(resp, :pepe_media, {0, []})
      seen = seen + byte_size(data)

      cond do
        declared(resp) > max ->
          {:halt, {req, Req.Response.put_private(resp, :pepe_media_over, true)}}

        seen > max ->
          {:halt, {req, Req.Response.put_private(resp, :pepe_media_over, true)}}

        true ->
          {:cont, {req, Req.Response.put_private(resp, :pepe_media, {seen, [data | chunks]})}}
      end
    end
  end

  defp declared(resp) do
    with [value | _] <- Req.Response.get_header(resp, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> 0
    end
  end

  defp body(resp, %{max_bytes: max}) do
    cond do
      private(resp, :pepe_media_over, false) ->
        {:error, :too_large}

      # Streamed by the collector above.
      match?({_, [_ | _]}, private(resp, :pepe_media, nil)) ->
        {_seen, chunks} = private(resp, :pepe_media, nil)
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      # Whatever answered without going through the collector (an empty body, or a stub).
      is_binary(resp.body) and byte_size(resp.body) > max ->
        {:error, :too_large}

      is_binary(resp.body) ->
        {:ok, resp.body}

      true ->
        {:ok, ""}
    end
  end

  defp redirect(resp, url, hops, ctx) do
    case header(resp, "location") do
      [location | _] when location != "" ->
        hop(url |> URI.merge(location) |> URI.to_string(), hops + 1, ctx)

      _ ->
        {:error, {:http, resp.status}}
    end
  end

  # Read off the response as a plain map, so a response that is not a `Req.Response` struct
  # (a test double) is read the same way as a real one.
  defp private(resp, key, default), do: resp |> Map.get(:private, %{}) |> Map.get(key, default)

  defp header(resp, name) do
    case Map.get(resp, :headers) do
      %{} = headers -> List.wrap(Map.get(headers, name, []))
      headers when is_list(headers) -> for {k, v} <- headers, String.downcase(to_string(k)) == name, do: v
      _ -> []
    end
  end
end
