defmodule Pepe.OAuth do
  @moduledoc """
  OAuth 2.0 sign-in (Authorization Code + PKCE/S256) for subscription providers.

  Generates the authorize link, opens the browser, captures the redirect on a
  local loopback server (`Pepe.OAuth.Callback`), and exchanges the code for
  tokens. Falls back to pasting the code/redirect-URL by hand when there is no
  callback server (remote/SSH) or the wait times out.

  A *flow spec* is a plain map (declared per provider in `Pepe.Providers`):

      %{
        authorize_url: "https://.../authorize",
        token_url: "https://.../token",
        client_id: "...",
        redirect_uri: "http://localhost:1455/auth/callback",
        callback_port: 1455,
        callback_path: "/auth/callback",
        scope: "openid profile email offline_access",
        token_content_type: :form | :json,   # default :form
        token_includes_state: false,          # some providers want state in the exchange
        extra_params: %{"originator" => "pepe", ...}
      }

  Returns `{:ok, %{access:, refresh:, expires_at:}}` or `{:error, reason}`.
  """

  alias Pepe.OAuth.Callback

  @callback_timeout_ms 180_000

  @spec login(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def login(flow, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:bandit)

    {verifier, challenge} = pkce()
    state = random_state()
    url = authorize_url(flow, challenge, state)

    ref = make_ref()
    server = start_callback(flow, state, ref, self())

    announce(url, server != nil)
    open_browser(url)

    result =
      with {:ok, code} <- await_code(ref, server, opts) do
        exchange(flow, code, verifier, state)
      end

    stop_callback(server)
    result
  end

  @doc """
  Start a **non-blocking** sign-in (for the dashboard). Starts the loopback callback
  and returns the authorize link plus a session to finish with. `owner` (default the
  caller) receives `{:oauth_code, ref, code}` or `{:oauth_error, ref, reason}` from the
  callback once the user authorizes in the browser. `session.pid` is `nil` if the
  loopback port couldn't bind (remote/in-use) - then finish by pasting the code instead.
  """
  @spec begin(map(), pid()) :: {:ok, map()}
  def begin(flow, owner \\ self()) do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {verifier, challenge} = pkce()
    state = random_state()
    url = authorize_url(flow, challenge, state)
    ref = make_ref()
    pid = start_callback(flow, state, ref, owner)
    {:ok, %{flow: flow, url: url, verifier: verifier, state: state, ref: ref, pid: pid}}
  end

  @doc "Exchange `code` for tokens using a `begin/2` session, then stop its callback server."
  @spec finish(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def finish(%{flow: flow, verifier: verifier, state: state} = session, code) do
    result = exchange(flow, code, verifier, state)
    cancel(session)
    result
  end

  @doc "Stop a `begin/2` session's loopback callback (e.g. when the user cancels)."
  def cancel(%{pid: pid}), do: stop_callback(pid)

  @doc """
  Build (not save) a `%Pepe.Config.Model{}` from a completed subscription sign-in:
  the provider's OAuth `method` spec (carrying base_url/api/models) plus the captured
  `tokens`. The model id defaults to the method's first offline fallback; edit later.
  """
  def subscription_connection(provider_key, method, name, tokens) do
    flow = method.oauth_flow

    %Pepe.Config.Model{
      name: name,
      base_url: method[:base_url] || Pepe.Providers.get(provider_key).base_url,
      api_key: tokens.access,
      model: List.first(method[:models] || []),
      api: method[:api] || "openai-completions",
      oauth: %{
        "provider" => provider_key,
        "refresh" => tokens.refresh,
        "expires_at" => tokens.expires_at,
        "token_url" => flow.token_url,
        "client_id" => flow.client_id,
        "token_content_type" => to_string(flow[:token_content_type] || :form)
      }
    }
  end

  @doc "Merge fresh `tokens` onto an existing OAuth connection (reconnect) and persist it."
  def apply_tokens(%Pepe.Config.Model{oauth: oauth} = model, tokens) when is_map(oauth),
    do: persist_refresh(model, oauth, tokens)

  @refresh_margin_seconds 60

  @doc """
  Return a model whose OAuth access token is valid, refreshing it (and persisting
  the new token to the connection) when it's expired or about to expire. A model
  without OAuth metadata is returned untouched; a refresh failure leaves the model
  as-is (the request then fails and is reported gracefully).
  """
  def ensure_fresh(%Pepe.Config.Model{oauth: oauth} = model) when is_map(oauth) do
    if fresh?(oauth["expires_at"]) do
      model
    else
      case refresh(oauth) do
        {:ok, tokens} -> persist_refresh(model, oauth, tokens)
        {:error, _reason} -> model
      end
    end
  end

  def ensure_fresh(model), do: model

  defp fresh?(expires_at) when is_integer(expires_at),
    do: System.os_time(:second) < expires_at - @refresh_margin_seconds

  # Unknown expiry -> assume valid (refresh would happen on a 401 instead).
  defp fresh?(_), do: true

  defp refresh(oauth) do
    {:ok, _} = Application.ensure_all_started(:req)

    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => oauth["refresh"],
      "client_id" => oauth["client_id"]
    }

    result =
      case oauth["token_content_type"] do
        "json" -> Req.post(oauth["token_url"], json: body)
        _ -> Req.post(oauth["token_url"], form: body)
      end

    case result do
      {:ok, %{status: 200, body: %{} = b}} ->
        {:ok,
         %{
           access: b["access_token"],
           refresh: b["refresh_token"],
           expires_at: expires_at(b["expires_in"])
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:refresh_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Redo the OAuth subscription sign-in for an existing model connection, by
  name, replacing its access/refresh token **in place** - every other field
  (base_url, model id, pricing, headers, fallbacks, ...) is left untouched.

  Use this when the refresh token itself died (subscription lapsed mid-call,
  was revoked, ...) - `ensure_fresh/1`'s silent refresh-grant can't recover
  from that, it just keeps handing back the same dead token. This runs a full
  fresh login instead, then merges only the credentials back onto the
  existing connection - nothing else about it changes, so every agent/cron
  already pointing at this connection name keeps working with no edits.
  """
  @spec reconnect(String.t()) :: {:ok, Pepe.Config.Model.t()} | {:error, term()}
  def reconnect(name) when is_binary(name) do
    case Pepe.Config.get_model(name) do
      nil ->
        {:error, :not_found}

      %Pepe.Config.Model{oauth: oauth} when not is_map(oauth) ->
        {:error, :not_oauth}

      %Pepe.Config.Model{oauth: oauth} = model ->
        do_reconnect(model, oauth)
    end
  end

  defp do_reconnect(model, oauth) do
    with provider when not is_nil(provider) <- Pepe.Providers.get(oauth["provider"]),
         flow when is_map(flow) <- oauth_flow(provider),
         {:ok, tokens} <- login(flow) do
      {:ok, persist_refresh(model, oauth, tokens)}
    else
      nil -> {:error, :unsupported_provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp oauth_flow(provider) do
    case Enum.find(Pepe.Providers.auth_methods(provider), &(&1[:type] == :oauth and is_map(&1[:oauth_flow]))) do
      %{oauth_flow: flow} -> flow
      _ -> nil
    end
  end

  defp persist_refresh(model, oauth, tokens) do
    new_oauth =
      oauth
      |> Map.put("refresh", tokens.refresh || oauth["refresh"])
      |> Map.put("expires_at", tokens.expires_at)

    updated = %{model | api_key: tokens.access, oauth: new_oauth}
    Pepe.Config.put_model(updated)
    updated
  end

  ###
  ### PKCE + authorize URL (public for testing)
  ###

  @doc "Generate a PKCE `{verifier, challenge}` pair (S256, base64url, unpadded)."
  def pkce do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  @doc "A random opaque `state` value."
  def random_state, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "Build the provider authorize URL for a flow spec."
  def authorize_url(flow, challenge, state) do
    params =
      %{
        "response_type" => "code",
        "client_id" => flow.client_id,
        "redirect_uri" => flow.redirect_uri,
        "scope" => flow.scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state
      }
      |> Map.merge(flow[:extra_params] || %{})

    flow.authorize_url <> "?" <> URI.encode_query(params)
  end

  ###
  ### loopback callback server
  ###

  defp start_callback(flow, state, ref, owner) do
    port = flow[:callback_port] || 1455
    path = flow[:callback_path] || "/auth/callback"
    plug = {Callback, owner: owner, ref: ref, state: state, path: path}

    opts = [plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: port, startup_log: false]

    # `Bandit.start_link/1` is a *supervisor* start: when the port can't be bound (in
    # use by another sign-in, privileged, no loopback on a remote box) it doesn't
    # merely hand back `{:error, _}` - it also fires an exit signal down the link,
    # which kills the caller outright before it can read that error. Trap it for the
    # duration of the start, so an unbindable port degrades to the paste-the-code
    # route (`pid: nil`) - which is the entire reason that route exists.
    trapping? = Process.flag(:trap_exit, true)

    pid =
      case Bandit.start_link(opts) do
        {:ok, pid} -> pid
        {:error, _reason} -> nil
      end

    Process.flag(:trap_exit, trapping?)
    pid
  end

  defp stop_callback(nil), do: :ok
  defp stop_callback(pid), do: Process.exit(pid, :normal)

  # No server (couldn't bind / remote): go straight to manual paste.
  defp await_code(_ref, nil, _opts), do: paste_code()

  defp await_code(ref, _server, opts) do
    timeout = opts[:timeout] || @callback_timeout_ms

    receive do
      {:oauth_code, ^ref, code} -> {:ok, code}
      {:oauth_error, ^ref, reason} -> {:error, reason}
    after
      timeout -> paste_code()
    end
  end

  defp paste_code do
    case Owl.IO.input(
           label: "Paste the authorization code (or full redirect URL):",
           optional: true
         ) do
      blank when blank in [nil, ""] -> {:error, :no_code}
      value -> {:ok, extract_code(value)}
    end
  end

  @doc "Pull the `code` out of a bare authorization code or a full redirect URL with `?code=...`."
  def extract_code(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{query: q} when is_binary(q) -> URI.decode_query(q)["code"] || value
      _ -> value
    end
  end

  ###
  ### token exchange
  ###

  defp exchange(flow, code, verifier, state) do
    body =
      %{
        "grant_type" => "authorization_code",
        "client_id" => flow.client_id,
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => flow.redirect_uri
      }
      |> maybe_put_state(flow, state)

    post_token(flow, body)
  end

  defp maybe_put_state(body, flow, state) do
    if flow[:token_includes_state], do: Map.put(body, "state", state), else: body
  end

  defp post_token(flow, body) do
    result =
      case flow[:token_content_type] || :form do
        :json -> Req.post(flow.token_url, json: body)
        :form -> Req.post(flow.token_url, form: body)
      end

    case result do
      {:ok, %{status: 200, body: %{} = b}} ->
        {:ok,
         %{
           access: b["access_token"],
           refresh: b["refresh_token"],
           expires_at: expires_at(b["expires_in"])
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expires_at(secs) when is_integer(secs), do: System.os_time(:second) + secs

  defp expires_at(secs) when is_binary(secs) do
    case Integer.parse(secs) do
      {n, _} -> System.os_time(:second) + n
      _ -> nil
    end
  end

  defp expires_at(_), do: nil

  ###
  ### browser + announce
  ###

  defp announce(url, server?) do
    link = "\e]8;;#{url}\e\\#{url}\e]8;;\e\\"
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Sign in to continue" <> IO.ANSI.reset())
    IO.puts("Opening your browser... if it doesn't open, click or paste this URL:\n  " <> link)

    if server?,
      do: IO.puts(IO.ANSI.faint() <> "Waiting for you to authorize in the browser..." <> IO.ANSI.reset())

    IO.puts("")
  end

  defp open_browser(url) do
    {cmd, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
        _ -> {"xdg-open", [url]}
      end

    spawn(fn ->
      try do
        System.cmd(cmd, args, stderr_to_stdout: true)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end
end
