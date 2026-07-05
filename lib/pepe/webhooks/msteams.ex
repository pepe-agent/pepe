defmodule Pepe.Webhooks.MsTeams do
  @moduledoc """
  Microsoft Teams provider (Bot Framework). Inbound activities arrive as webhook `POST`s
  to `/webhooks/:project/msteams/:slug`; replies go back to the activity's `serviceUrl`
  with an app access token minted via client credentials.

  A connection's `"config"` holds:

    * `app_id`       - the bot's Microsoft app id (client id)
    * `app_password` - the client secret (store as `${ENV_VAR}`)
    * `tenant_id`    - the tenant for the token endpoint (or `botframework.com`)

  Inbound requests are authenticated natively: each carries an `Authorization: Bearer`
  Bot Framework JWT, validated by `Pepe.Webhooks.MsTeamsJwt` (signature, issuer, and an
  `aud` equal to this bot's `app_id`). So the webhook accepts `POST`s straight from
  Microsoft, no validating proxy required. An operator who already terminates that check
  at a proxy can set `trust_proxy: true` to skip it. The reply carries the conversation
  and its `serviceUrl`, so it is addressed back to the right chat.
  """
  @behaviour Pepe.Webhooks.Provider

  alias Pepe.Config

  @impl true
  def name, do: "msteams"

  @impl true
  def label, do: "Microsoft Teams"

  @impl true
  def config_schema do
    [
      %{"key" => "app_id", "label" => "App id", "type" => "text", "hint" => "the bot's Microsoft app (client) id"},
      %{"key" => "app_password", "label" => "App password", "type" => "secret", "hint" => "the client secret; store as ${ENV_VAR}"},
      %{"key" => "tenant_id", "label" => "Tenant id", "type" => "text", "hint" => "the Azure tenant id (or botframework.com)"},
      %{
        "key" => "require_mention",
        "label" => "Require mention in channels",
        "type" => "select",
        "options" => ["true", "false"],
        "hint" => "in a team channel or group chat, reply only when the bot is @mentioned (default true); a 1:1 chat always replies"
      }
    ]
  end

  @impl true
  def verify(_config, _params), do: :error

  @impl true
  def authenticate(config, _raw_body, headers) do
    # The inbound Authorization bearer is a Bot Framework JWT. Validate it against Microsoft's
    # published keys so a predictable URL (`/webhooks/root/msteams/msteams`) cannot be POSTed by
    # anyone to drive the bound agent (arbitrary command execution if it holds `bash`). An operator
    # whose proxy already validates the token opts out with `trust_proxy: true`.
    pc = provider_config(config)

    if pc["trust_proxy"] == true do
      :ok
    else
      authenticate_jwt(pc, headers)
    end
  end

  defp authenticate_jwt(pc, headers) do
    with token when is_binary(token) <- bearer_token(headers),
         :ok <- Pepe.Webhooks.MsTeamsJwt.verify(token, pc["app_id"] || "") do
      :ok
    else
      _ -> :error
    end
  end

  defp bearer_token(headers) do
    case headers["authorization"] do
      "Bearer " <> token -> String.trim(token)
      "bearer " <> token -> String.trim(token)
      _ -> nil
    end
  end

  # A message activity: strip the bot @mention, address the reply by serviceUrl + convo id.
  @impl true
  def parse(%{"type" => "message"} = activity) do
    text = activity["text"]
    service_url = activity["serviceUrl"]
    conv = get_in(activity, ["conversation", "id"])
    from_bot? = get_in(activity, ["from", "role"]) == "bot"

    if is_binary(text) and text != "" and is_binary(service_url) and is_binary(conv) and not from_bot? do
      {:ok, [%{from: "#{service_url}|#{conv}", text: strip_mention(text), id: activity["id"]}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # A 1:1 chat always reaches the agent. In a team channel or group chat, optionally
  # require the bot be @mentioned (a native `mention` entity targeting the bot's own
  # recipient id) so it doesn't answer every message.
  @impl true
  def addressed?(config, %{"type" => "message"} = activity) do
    cond do
      get_in(activity, ["conversation", "conversationType"]) == "personal" -> true
      mentions_bot?(activity) -> true
      require_mention?(config) == false -> true
      true -> false
    end
  end

  def addressed?(_config, _payload), do: true

  defp mentions_bot?(activity) do
    bot_id = get_in(activity, ["recipient", "id"])

    activity
    |> Map.get("entities", [])
    |> Enum.any?(fn e -> e["type"] == "mention" and get_in(e, ["mentioned", "id"]) == bot_id end)
  end

  defp require_mention?(config), do: provider_config(config)["require_mention"] != "false"

  defp strip_mention(text), do: text |> String.replace(~r{<at>.*?</at>}, "") |> String.trim()

  # The hosts the reply (and its bearer token) may be sent to. The `serviceUrl` arrives in the
  # inbound payload, so without this an attacker who reaches `parse/1` could point it at their own
  # server and receive the connector bearer token in the Authorization header. These are the
  # public-cloud Bot Framework hosts; regional/gov/self-hosted deployments add theirs via the
  # connection's `service_hosts` (an entry starting with `.` is a domain suffix, else an exact
  # host).
  @default_service_hosts ~w(smba.trafficmanager.net .botframework.com .botframework.us)

  @impl true
  def deliver(config, addr, text) do
    [service_url, conv] = String.split(addr, "|", parts: 2)
    pc = provider_config(config)

    with :ok <- allowed_service_url(service_url, pc),
         {:ok, token} <- access_token(pc) do
      url = "#{String.trim_trailing(service_url, "/")}/v3/conversations/#{conv}/activities"
      body = %{"type" => "message", "text" => text, "textFormat" => "markdown"}

      case Req.post(url, auth: {:bearer, token}, json: body, receive_timeout: 15_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: b}} -> {:error, {:msteams, s, b}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp allowed_service_url(url, pc) do
    hosts = @default_service_hosts ++ List.wrap(pc["service_hosts"])

    with {:ok, %URI{scheme: "https", host: host}} when is_binary(host) <- URI.new(url),
         true <- Enum.any?(hosts, &host_match?(host, &1)) do
      :ok
    else
      _ -> {:error, :untrusted_service_url}
    end
  end

  defp host_match?(host, "." <> _ = suffix), do: String.ends_with?(host, suffix)
  defp host_match?(host, exact), do: host == exact

  # Client-credentials token for the Bot Framework connector.
  defp access_token(pc) do
    app_id = pc["app_id"]
    secret = Config.interpolate(pc["app_password"])
    tenant = pc["tenant_id"] || "botframework.com"

    cond do
      is_nil(app_id) or app_id == "" -> {:error, :no_app_id}
      is_nil(secret) or secret == "" -> {:error, :no_app_password}
      true -> request_token(tenant, app_id, secret)
    end
  end

  defp request_token(tenant, app_id, secret) do
    url = "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token"

    form = %{
      "grant_type" => "client_credentials",
      "client_id" => app_id,
      "client_secret" => secret,
      "scope" => "https://api.botframework.com/.default"
    }

    case Req.post(url, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: s, body: b}} -> {:error, {:token, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_config(config), do: config["config"] || %{}
end
