defmodule Pepe.Webhooks.Slack do
  @moduledoc """
  Slack provider (Events API). Inbound arrives as webhook `POST`s to
  `/webhooks/:company/slack/:slug`; replies go to the Web API `chat.postMessage`.

  A connection's `"config"` holds:

    * `bot_token`      - the bot user OAuth token (`xoxb-...`), the Bearer for replies
    * `signing_secret` - verifies the `X-Slack-Signature` on inbound requests

  Point the Slack app's Event Subscriptions request URL at the connection URL and
  subscribe to `message.channels` / `app_mention`. The first save triggers a
  `url_verification` handshake, answered synchronously here.
  """
  @behaviour Pepe.Webhooks.Provider

  require Logger

  alias Pepe.Config

  @api "https://slack.com/api"

  @impl true
  def name, do: "slack"

  @impl true
  def label, do: "Slack"

  @impl true
  def config_schema do
    [
      %{"key" => "bot_token", "label" => "Bot token", "type" => "secret", "hint" => "xoxb-... ; store as ${ENV_VAR}"},
      %{
        "key" => "signing_secret",
        "label" => "Signing secret",
        "type" => "secret",
        "hint" => "from the app's Basic Information; store as ${ENV_VAR}"
      },
      %{
        "key" => "require_mention",
        "label" => "Require mention in channels",
        "type" => "select",
        "options" => ["true", "false"],
        "hint" => "in a channel, reply only when the bot is @mentioned (default true); a direct message always replies"
      }
    ]
  end

  # No GET handshake; Slack verifies over a POST (see respond/3).
  @impl true
  def verify(_config, _params), do: :error

  # Answer the url_verification challenge synchronously.
  @impl true
  def respond(_config, %{"type" => "url_verification", "challenge" => challenge}, _headers)
      when is_binary(challenge),
      do: {:reply, 200, "text/plain", challenge}

  def respond(_config, _payload, _headers), do: :cont

  @impl true
  def authenticate(config, raw_body, headers) do
    case Config.interpolate(provider_config(config)["signing_secret"]) do
      secret when is_binary(secret) and secret != "" ->
        ts = headers["x-slack-request-timestamp"] || ""
        given = headers["x-slack-signature"] || ""
        expected = "v0=" <> hmac_hex(secret, "v0:#{ts}:#{raw_body}")
        if Plug.Crypto.secure_compare(expected, given), do: :ok, else: :error

      _ ->
        Logger.warning("[slack] no signing_secret set; inbound signature unverified")
        :ok
    end
  end

  @impl true
  def parse(%{"type" => "event_callback", "event" => event}) do
    if user_message?(event) do
      {:ok, [%{from: event["channel"], text: event["text"], id: event["ts"]}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # A real message from a person: a message/app_mention event with text, not a bot echo
  # (no bot_id) and not an edit/join/etc. subtype.
  defp user_message?(%{"type" => type} = event) when type in ["message", "app_mention"] do
    is_binary(event["text"]) and event["text"] != "" and
      is_nil(event["bot_id"]) and is_nil(event["subtype"])
  end

  defp user_message?(_), do: false

  # A direct message always reaches the agent. In a channel, `app_mention` is Slack's
  # own unambiguous "the bot was mentioned" event; a plain `message` event in a
  # channel only counts when require_mention is off (set up both subscriptions, per
  # the moduledoc, so a real mention always also arrives as app_mention).
  @impl true
  def addressed?(_config, %{"type" => "event_callback", "event" => %{"type" => "app_mention"}}),
    do: true

  def addressed?(_config, %{"type" => "event_callback", "event" => %{"channel_type" => "im"}}),
    do: true

  def addressed?(config, %{"type" => "event_callback", "event" => %{"type" => "message"} = event}) do
    require_mention?(config) == false or String.starts_with?(event["channel"] || "", "D")
  end

  def addressed?(_config, _payload), do: true

  defp require_mention?(config), do: provider_config(config)["require_mention"] != "false"

  @impl true
  def deliver(config, channel, text) do
    token = Config.interpolate(provider_config(config)["bot_token"])

    if is_binary(token) and token != "" do
      case Req.post("#{@api}/chat.postMessage",
             auth: {:bearer, token},
             json: %{"channel" => channel, "text" => text},
             receive_timeout: 15_000
           ) do
        {:ok, %{status: s, body: %{"ok" => true}}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, {:slack, s, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_bot_token}
    end
  end

  @impl true
  def deliver_file(config, channel, path, caption) do
    token = Config.interpolate(provider_config(config)["bot_token"])

    if is_binary(token) and token != "" do
      parts =
        [channels: channel, filename: Path.basename(path), file: {File.stream!(path), filename: Path.basename(path)}]
        |> then(fn f -> if caption in [nil, ""], do: f, else: [{:initial_comment, caption} | f] end)

      case Req.post("#{@api}/files.upload", auth: {:bearer, token}, form_multipart: parts, receive_timeout: 120_000) do
        {:ok, %{status: s, body: %{"ok" => true}}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, {:slack, s, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_bot_token}
    end
  end

  defp provider_config(config), do: config["config"] || %{}

  defp hmac_hex(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
end
