defmodule Pepe.Webhooks.GoogleChat do
  @moduledoc """
  Google Chat provider. Space events arrive as webhook `POST`s to
  `/webhooks/:project/googlechat/:slug`; replies are posted asynchronously to the Chat
  REST API so a slow agent turn does not block the request.

  A connection's `"config"` holds:

    * `access_token`   - an OAuth token for the Chat API (Bearer for replies; store as
      `${ENV_VAR}` and refresh it out of band)
    * `project_number` - the Cloud project number the Chat app is registered under (the Chat
      app's "Authentication Audience" setting must be set to **Project Number**, not "HTTP
      endpoint URL" - a different token shape this provider does not verify)

  Inbound requests are authenticated natively: each carries an `Authorization: Bearer` Google-
  signed JWT, validated by `Pepe.Webhooks.GoogleChatJwt` (signature, issuer, and an `aud` equal
  to `project_number`). So the webhook accepts `POST`s straight from Google, no validating proxy
  required. An operator who already terminates that check at a proxy can set `trust_proxy: true`
  to skip it. Only `MESSAGE` events from a human are acted on.
  """
  @behaviour Pepe.Webhooks.Provider

  alias Pepe.Config

  @api "https://chat.googleapis.com/v1"

  @impl true
  def name, do: "googlechat"

  @impl true
  def label, do: "Google Chat"

  @impl true
  def config_schema do
    [
      %{
        "key" => "access_token",
        "label" => "Access token",
        "type" => "secret",
        "hint" => "an OAuth token for the Chat API; store as ${ENV_VAR}"
      },
      %{
        "key" => "project_number",
        "label" => "Project number",
        "type" => "text",
        "hint" =>
          "the Cloud project number the Chat app is registered under; the app's Authentication Audience must be set to \"Project Number\""
      },
      %{
        "key" => "require_mention",
        "label" => "Require mention in spaces",
        "type" => "select",
        "options" => ["true", "false"],
        "hint" => "in a multi-person space, reply only when the app is @mentioned (default true); a direct message always replies"
      }
    ]
  end

  @impl true
  def verify(_config, _params), do: :error

  @impl true
  def authenticate(config, _raw_body, headers) do
    # The inbound Authorization bearer is a Google-signed JWT. Validate it against Google's
    # published keys so a predictable URL (`/webhooks/root/googlechat/googlechat`) cannot be
    # POSTed by anyone to drive the bound agent (arbitrary command execution if it holds `bash`).
    # An operator whose proxy already validates the token opts out with `trust_proxy: true`.
    pc = provider_config(config)

    if pc["trust_proxy"] == true do
      :ok
    else
      authenticate_jwt(pc, headers)
    end
  end

  defp authenticate_jwt(pc, headers) do
    with token when is_binary(token) <- bearer_token(headers),
         :ok <- Pepe.Webhooks.GoogleChatJwt.verify(token, to_string(pc["project_number"] || "")) do
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

  # Only a human MESSAGE becomes a turn; reply is addressed to the space.
  @impl true
  def parse(%{"type" => "MESSAGE", "message" => message, "space" => space}) do
    text = message["argumentText"] || message["text"]
    human? = get_in(message, ["sender", "type"]) != "BOT"

    if is_binary(text) and text != "" and human? and is_binary(space["name"]) do
      {:ok, [%{from: space["name"], text: String.trim(text), id: message["name"]}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # DMs always reach the agent. In a multi-person space, optionally require the app
  # be @mentioned (native USER_MENTION annotation targeting the app itself) so it
  # doesn't answer every message.
  @impl true
  def addressed?(config, %{"type" => "MESSAGE", "message" => message, "space" => space}) do
    cond do
      space["type"] in ["DM", "DIRECT_MESSAGE"] -> true
      mentions_app?(message) -> true
      require_mention?(config) == false -> true
      true -> false
    end
  end

  def addressed?(_config, _payload), do: true

  defp mentions_app?(message) do
    message
    |> Map.get("annotations", [])
    |> Enum.any?(fn a ->
      a["type"] == "USER_MENTION" and get_in(a, ["userMention", "user", "name"]) == "users/app"
    end)
  end

  defp require_mention?(config), do: provider_config(config)["require_mention"] != "false"

  @impl true
  def deliver(config, space, text) do
    token = Config.interpolate(provider_config(config)["access_token"])

    if is_binary(token) and token != "" do
      case Req.post("#{@api}/#{space}/messages", auth: {:bearer, token}, json: %{"text" => text}, receive_timeout: 15_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: b}} -> {:error, {:googlechat, s, b}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_access_token}
    end
  end

  defp provider_config(config), do: config["config"] || %{}
end
