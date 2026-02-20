defmodule Pepe.OAuth do
  @moduledoc """
  OAuth 2.0 sign-in (Authorization Code + PKCE/S256) for subscription providers.

  Generates the authorize link, opens the browser, captures the redirect on a
  local loopback server (`Pepe.OAuth.Callback`), and exchanges the code for
  tokens. Falls back to pasting the code/redirect-URL by hand when there is no
  callback server (remote/SSH) or the wait times out.

  A *flow spec* is a plain map (declared per provider in `Pepe.Providers`):

      %{
        authorize_url: "https://…/authorize",
        token_url: "https://…/token",
        client_id: "…",
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
    server = start_callback(flow, state, ref)

    announce(url, server != nil)
    open_browser(url)

    result =
      with {:ok, code} <- await_code(ref, server, opts),
           {:ok, tokens} <- exchange(flow, code, verifier, state) do
        {:ok, tokens}
      end

    stop_callback(server)
    result
  end

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

  # Unknown expiry → assume valid (refresh would happen on a 401 instead).
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

  defp start_callback(flow, state, ref) do
    port = flow[:callback_port] || 1455
    path = flow[:callback_path] || "/auth/callback"
    plug = {Callback, owner: self(), ref: ref, state: state, path: path}

    opts = [plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: port, startup_log: false]

    case Bandit.start_link(opts) do
      {:ok, pid} -> pid
      {:error, _} -> nil
    end
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

  # Accept a bare code, or a full redirect URL with `?code=…`.
  defp extract_code(value) do
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
    IO.puts("Opening your browser… if it doesn't open, click or paste this URL:\n  " <> link)

    if server?,
      do:
        IO.puts(
          IO.ANSI.faint() <> "Waiting for you to authorize in the browser…" <> IO.ANSI.reset()
        )

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
