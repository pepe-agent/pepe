defmodule Pepe.MCP.OAuth do
  @moduledoc """
  OAuth 2.1 for remote MCP servers: the parts MCP adds on top of an ordinary authorization
  code flow, which is `Pepe.OAuth`'s job and is not repeated here.

  What MCP adds is that **nothing is known in advance**. A subscription provider ships with
  a client id and fixed endpoints, declared in `Pepe.Providers`. An MCP server hands you a
  URL and nothing else, so the flow starts by asking the server itself:

    1. **Where is the authorization server?** The MCP server's
       `/.well-known/oauth-protected-resource` (RFC 9728) names it. A `401` also carries it
       in `WWW-Authenticate`, which is how a server that only reveals this when challenged
       gets discovered.
    2. **What are its endpoints?** `/.well-known/oauth-authorization-server` (RFC 8414), or
       the OpenID equivalent for issuers that publish only that one.
    3. **Who are we?** Nobody, yet - so we ask for an identity: dynamic client registration
       (RFC 7591) returns a client id minted for this Pepe install. This is the step with no
       counterpart in the provider flows, and the one that makes "just give it the URL"
       possible at all.

  Then `Pepe.OAuth.login/2` takes over for the browser, PKCE and the code exchange, and the
  result lands in `Pepe.MCP.Credential`.

  Sign-in is deliberately **operator-initiated** (`mix pepe mcp login NAME`) and never
  happens on the path of an agent's tool call. An agent hitting a 401 mid-conversation
  cannot open a browser on a server, and a tool call that silently blocks for three minutes
  waiting for a human to click something is worse than one that fails saying what to run.
  """

  require Logger

  alias Pepe.Config
  alias Pepe.MCP.Credential
  alias Pepe.Repo

  @refresh_margin_seconds 60
  @callback_port 1456
  @callback_path "/callback"
  @discovery_timeout 15_000

  ###
  ### tokens
  ###

  @doc """
  A usable access token for `server`, refreshing it first when it has expired.

  `{:error, :none}` for a server nobody signed into, which is the common and unremarkable
  case: most remote servers use a static API key header and never touch this.
  """
  @spec token(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def token(nil), do: {:error, :none}

  def token(server) do
    case credential(server) do
      nil -> {:error, :none}
      credential -> fresh(credential)
    end
  end

  defp fresh(%Credential{} = credential) do
    if valid?(credential.expires_at) do
      {:ok, credential.access_token}
    else
      refresh(credential)
    end
  end

  # No expiry recorded means the server never said - treat as valid and let a 401 be the
  # thing that proves otherwise, rather than refreshing on every single call.
  defp valid?(nil), do: true
  defp valid?(expires_at), do: System.os_time(:second) < expires_at - @refresh_margin_seconds

  defp refresh(%Credential{refresh_token: nil} = credential),
    do: {:ok, credential.access_token}

  defp refresh(%Credential{} = credential) do
    case Pepe.OAuth.refresh(Credential.to_oauth(credential)) do
      {:ok, tokens} ->
        {:ok, stored} = store_tokens(credential, tokens)
        {:ok, stored.access_token}

      {:error, reason} ->
        # The old token is kept: it may still work (a server that ignores expiry), and
        # dropping it would turn a recoverable refresh hiccup into a forced re-login.
        Logger.warning("[mcp] token refresh failed for #{credential.server}: #{inspect(reason)}")
        {:ok, credential.access_token}
    end
  end

  ###
  ### sign-in
  ###

  @doc """
  Run the full sign-in for a configured MCP server and store the resulting grant.

  Returns `{:ok, credential}` or `{:error, reason}`. Blocks while the operator authorizes in
  a browser (`Pepe.OAuth` falls back to pasting the redirect URL when there is no browser,
  which is the normal case over SSH).
  """
  @spec login(String.t()) :: {:ok, Credential.t()} | {:error, term()}
  def login(server) do
    with {:ok, spec} <- remote_spec(server),
         {:ok, meta} <- discover(spec.url),
         {:ok, client} <- client_identity(server, meta, spec),
         {:ok, tokens} <- Pepe.OAuth.login(flow(meta, client, spec)),
         {:ok, credential} <- persist(server, spec, meta, client, tokens) do
      {:ok, credential}
    end
  end

  @doc """
  Start a sign-in without blocking on it, for the dashboard: returns
  `{:ok, session, authorize_url}` where `session` is what `finish/3` needs and the URL is
  what the operator has to open. `owner` (default the caller) is sent
  `{:oauth_code, ref, code}` when the browser comes back to the loopback callback.

  The blocking `login/1` is right for a terminal, where waiting *is* the interface. A
  LiveView cannot block for three minutes without freezing the page, so it gets the same
  flow taken apart at the point where a human has to do something.
  """
  @spec begin(String.t(), pid()) :: {:ok, map(), String.t()} | {:error, term()}
  def begin(server, owner \\ self()) do
    with {:ok, spec} <- remote_spec(server),
         {:ok, meta} <- discover(spec.url),
         {:ok, client} <- client_identity(server, meta, spec) do
      {:ok, session} = Pepe.OAuth.begin(flow(meta, client, spec), owner)
      {:ok, Map.merge(session, %{server: server, spec: spec, meta: meta, client: client}), session.url}
    end
  end

  @doc "Finish a `begin/2` sign-in with the code the browser (or the operator) produced."
  @spec finish(map(), String.t()) :: {:ok, Credential.t()} | {:error, term()}
  def finish(%{server: server, spec: spec, meta: meta, client: client} = session, code) do
    with {:ok, tokens} <- Pepe.OAuth.finish(session, code) do
      persist(server, spec, meta, client, tokens)
    end
  end

  @doc "Forget a server's grant. The next call falls back to whatever headers are configured."
  @spec logout(String.t()) :: :ok
  def logout(server) do
    if repo?() do
      case credential(server) do
        nil -> :ok
        credential -> Repo.delete!(credential) && :ok
      end
    else
      :ok
    end
  end

  @doc "The stored grant for a server, or nil."
  @spec credential(String.t()) :: Credential.t() | nil
  def credential(server) do
    # The MCP client asks for a token during its own init, which happens in CLI one-shots
    # and in tests where no Repo is running. "No store" has to mean "no token", not a
    # crash inside a transport's startup.
    if repo?(), do: Repo.get(Credential, server), else: nil
  end

  ###
  ### discovery
  ###

  @doc """
  Everything needed to run the flow against `url`'s authorization server:
  `%{issuer:, authorize_url:, token_url:, registration_url:, scopes:}`.
  """
  @spec discover(String.t()) :: {:ok, map()} | {:error, term()}
  def discover(url) do
    with {:ok, issuer} <- authorization_server_for(url),
         {:ok, meta} <- server_metadata(issuer) do
      {:ok, meta}
    end
  end

  # RFC 9728: the resource says which authorization server governs it. A server that
  # publishes nothing is assumed to be its own issuer, which is what small self-hosted
  # deployments (one app, one auth) actually do.
  defp authorization_server_for(url) do
    case get_json(well_known(url, "oauth-protected-resource")) do
      {:ok, %{"authorization_servers" => [issuer | _]}} -> {:ok, issuer}
      _ -> {:ok, origin(url)}
    end
  end

  defp server_metadata(issuer) do
    with {:error, _} <- fetch_metadata(well_known(issuer, "oauth-authorization-server")),
         {:error, reason} <- fetch_metadata(well_known(issuer, "openid-configuration")) do
      {:error, {:mcp_no_oauth_metadata, issuer, reason}}
    else
      {:ok, meta} -> {:ok, Map.put(meta, :issuer, issuer)}
    end
  end

  defp fetch_metadata(url) do
    case get_json(url) do
      {:ok, %{"authorization_endpoint" => authorize, "token_endpoint" => token} = body} ->
        {:ok,
         %{
           authorize_url: authorize,
           token_url: token,
           registration_url: body["registration_endpoint"],
           scopes: body["scopes_supported"] || []
         }}

      {:ok, _incomplete} ->
        {:error, {:incomplete_metadata, url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The `resource_metadata` URL a `401` points at, when it carries one. Reported by the
  transports so an unauthorized server says where to go rather than just "401".
  """
  def challenge(resp) do
    resp
    |> Req.Response.get_header("www-authenticate")
    |> Enum.find_value(fn header ->
      case Regex.run(~r/resource_metadata="([^"]+)"/, header) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  ###
  ### client identity
  ###

  # A client id the operator pinned in config wins; otherwise register for one. Pinning
  # matters for an authorization server that refuses dynamic registration and expects a
  # client created by hand in its admin UI.
  defp client_identity(_server, meta, spec) do
    case configured_client(spec) do
      %{client_id: id} = client when is_binary(id) and id != "" ->
        {:ok, client}

      _ ->
        register(meta, spec)
    end
  end

  defp configured_client(spec) do
    oauth = spec[:oauth] || %{}

    %{
      client_id: Pepe.MCP.Protocol.interp(oauth["client_id"] || ""),
      client_secret: Pepe.MCP.Protocol.interp(oauth["client_secret"] || "")
    }
  end

  defp register(%{registration_url: nil}, _spec),
    do: {:error, :mcp_no_registration_endpoint}

  defp register(%{registration_url: url}, spec) do
    body = %{
      "client_name" => "Pepe",
      "redirect_uris" => [redirect_uri(spec)],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      # PKCE-only public client: no secret to leak out of the SQLite file if the server
      # is willing to mint one that way. A server that insists on a secret returns one
      # anyway, and it is stored and used.
      "token_endpoint_auth_method" => "none"
    }

    case Req.post(url, json: body, receive_timeout: @discovery_timeout) do
      {:ok, %{status: status, body: %{"client_id" => id} = resp}} when status in 200..299 ->
        {:ok, %{client_id: id, client_secret: resp["client_secret"]}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:mcp_registration_failed, status, resp}}

      {:error, reason} ->
        {:error, {:mcp_registration_failed, reason}}
    end
  end

  ###
  ### flow + storage
  ###

  defp flow(meta, client, spec) do
    %{
      authorize_url: meta.authorize_url,
      token_url: meta.token_url,
      client_id: client.client_id,
      client_secret: client[:client_secret],
      redirect_uri: redirect_uri(spec),
      callback_port: callback_port(spec),
      callback_path: @callback_path,
      scope: scope(meta, spec),
      token_content_type: :form,
      # RFC 8707. MCP requires the token to be bound to the server it is for, so a token
      # minted for one MCP server cannot be replayed against another sharing an issuer.
      extra_params: %{"resource" => spec.url},
      token_extra_params: %{"resource" => spec.url}
    }
  end

  defp scope(meta, spec) do
    case spec[:oauth]["scope"] do
      s when is_binary(s) and s != "" -> s
      _ -> Enum.join(meta.scopes, " ")
    end
  end

  defp redirect_uri(spec), do: "http://127.0.0.1:#{callback_port(spec)}#{@callback_path}"

  defp callback_port(spec) do
    case spec[:oauth]["callback_port"] do
      port when is_integer(port) -> port
      _ -> @callback_port
    end
  end

  defp persist(server, spec, meta, client, tokens) do
    if repo?() do
      attrs = %{
        server: server,
        issuer: meta[:issuer],
        token_url: meta.token_url,
        registration_url: meta[:registration_url],
        client_id: client.client_id,
        client_secret: client[:client_secret],
        scope: scope(meta, spec),
        resource: spec.url,
        access_token: tokens.access,
        refresh_token: tokens[:refresh],
        expires_at: tokens[:expires_at],
        created: System.os_time(:second)
      }

      %Credential{}
      |> Credential.changeset(attrs)
      |> Repo.insert(on_conflict: :replace_all, conflict_target: :server)
    else
      {:error, :no_store}
    end
  end

  defp store_tokens(%Credential{} = credential, tokens) do
    credential
    |> Credential.changeset(%{
      access_token: tokens.access,
      # A rotating refresh token is replaced; a server that reuses one sends none back,
      # and blanking it there would break every refresh after this one.
      refresh_token: tokens[:refresh] || credential.refresh_token,
      expires_at: tokens[:expires_at]
    })
    |> Repo.update()
  end

  ###
  ### helpers
  ###

  defp remote_spec(server) do
    case Config.mcp_server(server) do
      nil -> {:error, {:unknown_server, server}}
      %{url: url} = spec when is_binary(url) and url != "" -> {:ok, spec}
      _ -> {:error, {:not_a_remote_server, server}}
    end
  end

  defp get_json(url) do
    case Req.get(url, receive_timeout: @discovery_timeout, retry: :transient) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp well_known(url, suffix), do: origin(url) <> "/.well-known/" <> suffix

  defp origin(url) do
    uri = URI.parse(url)
    %URI{scheme: uri.scheme, host: uri.host, port: uri.port} |> URI.to_string()
  end

  defp repo?, do: is_pid(Process.whereis(Repo))
end
