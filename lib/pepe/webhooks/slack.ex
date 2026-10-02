defmodule Pepe.Webhooks.Slack do
  @moduledoc """
  Slack provider (Events API). Inbound arrives as webhook `POST`s to
  `/webhooks/:project/slack/:slug`; replies go to the Web API `chat.postMessage`.

  A connection's `"config"` holds:

    * `bot_token`      - the bot user OAuth token (`xoxb-...`), the Bearer for replies
    * `signing_secret` - verifies the `X-Slack-Signature` on inbound requests

  Pictures and files sent to the bot are read like on any other channel (see
  `Pepe.Webhooks.Media`); that needs the `files:read` scope on the Slack app.

  Point the Slack app's Event Subscriptions request URL at the connection URL and
  subscribe to `message.channels` / `app_mention`. The first save triggers a
  `url_verification` handshake, answered synchronously here.
  """
  @behaviour Pepe.Webhooks.Provider
  use Gettext, backend: Pepe.Gettext

  alias Pepe.Config

  @api "https://slack.com/api"

  @impl true
  def name, do: "slack"

  @impl true
  def label, do: "Slack"

  @impl true
  def config_schema do
    [
      %{
        "key" => "bot_token",
        "label" => dgettext("webhooks", "Bot token"),
        "type" => "secret",
        "hint" => dgettext("webhooks", "Starts with xoxb-. Write it as ${ENV_VAR}.")
      },
      %{
        "key" => "signing_secret",
        "label" => dgettext("webhooks", "Signing secret"),
        "type" => "secret",
        "hint" => dgettext("webhooks", "Find it on the app's Basic Information page. Write it as ${ENV_VAR}.")
      },
      %{
        "key" => "require_mention",
        "label" => dgettext("webhooks", "Answer only when mentioned"),
        "type" => "select",
        "options" => ["true", "false"],
        "hint" => dgettext("webhooks", "In channels, reply only when someone @mentions the bot (default: yes).")
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
        if Plug.Crypto.secure_compare(expected, given) and fresh?(ts), do: :ok, else: :error

      _ ->
        Pepe.Webhooks.Provider.unsigned_inbound("slack")
    end
  end

  # Slack signs the request timestamp into the HMAC and recommends rejecting anything older than
  # five minutes. The signature alone does not stop replay - a captured, still-valid request can
  # be re-sent verbatim - but the timestamp window does: an attacker cannot move `ts` forward
  # without the signing secret, so a stale one is refused.
  @max_age_seconds 300

  defp fresh?(ts) do
    case Integer.parse(to_string(ts)) do
      {t, _} -> abs(System.system_time(:second) - t) <= @max_age_seconds
      :error -> false
    end
  end

  @impl true
  def parse(%{"type" => "event_callback", "event" => event}) do
    if user_message?(event) do
      {:ok, [%{from: event["channel"], text: strip_mention(event["text"] || ""), id: event["ts"], media: media(event)}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # A real message from a person: a message/app_mention event with text or a file, not a
  # bot echo (no bot_id) and not an edit/join/etc. subtype. A message with an attachment
  # arrives as the `file_share` subtype, so that one is let through.
  defp user_message?(%{"type" => type} = event) when type in ["message", "app_mention"] do
    (text?(event) or media(event) != []) and
      is_nil(event["bot_id"]) and event["subtype"] in [nil, "file_share"]
  end

  defp user_message?(_), do: false

  defp text?(event), do: is_binary(event["text"]) and event["text"] != ""

  # The files attached to the message. `url_private_download` needs the bot's token
  # (`files:read` scope) and is fetched later by `fetch_media/2`.
  defp media(event) do
    for f <- List.wrap(event["files"]), is_map(f), is_binary(f["url_private_download"] || f["url_private"]) do
      %{
        kind: kind(f["mimetype"], f["name"]),
        ref: f["url_private_download"] || f["url_private"],
        filename: f["name"],
        mime: f["mimetype"],
        size: f["size"]
      }
    end
  end

  defp kind(mime, name) do
    case to_string(mime || MIME.from_path(to_string(name))) do
      "audio/" <> _ -> "audio"
      "image/" <> _ -> "image"
      "video/" <> _ -> "video"
      _ -> "document"
    end
  end

  @doc """
  Fetch an attachment off Slack's file host with the bot's token. The url comes off the wire,
  so the host is pinned to Slack's own, and the transfer is cut at the connection's size
  limit. Without the `files:read` scope Slack answers with a login page instead of the
  bytes, which is refused here rather than handed to the agent as the file.
  """
  @impl true
  def fetch_media(config, %{ref: url} = media) when is_binary(url) do
    token = Config.interpolate(provider_config(config)["bot_token"])

    with true <- (is_binary(token) and token != "") or {:error, :no_bot_token},
         :ok <- Pepe.Webhooks.Media.within_cap(media[:size], config),
         {:ok, bytes} <-
           Pepe.Webhooks.Media.Download.get(url,
             hosts: ["files.slack.com"],
             bearer: token,
             max_bytes: Pepe.Webhooks.Media.max_bytes(config)
           ) do
      if String.starts_with?(bytes, "<!DOCTYPE html") or String.starts_with?(bytes, "<html"),
        do: {:error, :missing_files_read_scope},
        else: {:ok, bytes}
    else
      {:error, :bad_url} -> {:error, :bad_attachment_url}
      {:error, _} = error -> error
    end
  end

  def fetch_media(_config, _media), do: {:error, :no_attachment_url}

  # An app_mention's text leads with the bot's own <@U...> mention (Slack doesn't
  # strip it the way MS Teams'/Google Chat's own APIs do) - drop it so "@bot /new"
  # and "@bot /mention off" parse as the command they are, not plain chat text that
  # happens to start with a mention.
  defp strip_mention(text), do: text |> String.replace(~r/^\s*<@[A-Z0-9]+>\s*/, "") |> String.trim()

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

  @doc """
  Renders `Pepe.Presentation` blocks into real Slack Block Kit (`section`s for text/table,
  an `actions` block of real buttons) instead of falling back to plain text - Slack's
  native rich-message format, sent the same way `deliver/3` does.
  """
  @impl true
  def deliver_blocks(config, channel, blocks) do
    token = Config.interpolate(provider_config(config)["bot_token"])

    if is_binary(token) and token != "" do
      case Req.post("#{@api}/chat.postMessage",
             auth: {:bearer, token},
             json: %{
               "channel" => channel,
               "text" => Pepe.Presentation.to_text(blocks),
               "blocks" => blocks |> Enum.map(&to_block_kit/1) |> Enum.reject(&is_nil/1)
             },
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

  defp to_block_kit(%{"type" => "text", "text" => text}) do
    %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}
  end

  # Block Kit has no native table element - a monospace mrkdwn block is the same
  # rendering approach most Slack bots use for tabular data.
  defp to_block_kit(%{"type" => "table"} = block) do
    %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "```\n#{Pepe.Presentation.to_text([block])}\n```"}}
  end

  defp to_block_kit(%{"type" => "buttons", "buttons" => buttons}) do
    %{
      "type" => "actions",
      "elements" =>
        Enum.map(buttons, fn b ->
          %{
            "type" => "button",
            "text" => %{"type" => "plain_text", "text" => b["label"]},
            "value" => to_string(b["value"] || b["label"])
          }
        end)
    }
  end

  # An unrecognized block type: dropped rather than rendered as an empty section, which
  # Slack's real API would reject with invalid_blocks and fail the whole message over one
  # stray block - same "silently drop what a text fallback can't render" rule as
  # `Pepe.Presentation.to_text/1` itself.
  defp to_block_kit(_other), do: nil

  @impl true
  def deliver_file(config, channel, path, caption) do
    token = Config.interpolate(provider_config(config)["bot_token"])

    if is_binary(token) and token != "" do
      parts =
        with_initial_comment(
          [channels: channel, filename: Path.basename(path), file: {File.stream!(path), filename: Path.basename(path)}],
          caption
        )

      case Req.post("#{@api}/files.upload", auth: {:bearer, token}, form_multipart: parts, receive_timeout: 120_000) do
        {:ok, %{status: s, body: %{"ok" => true}}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, {:slack, s, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_bot_token}
    end
  end

  defp with_initial_comment(parts, caption) when caption in [nil, ""], do: parts
  defp with_initial_comment(parts, caption), do: [{:initial_comment, caption} | parts]

  defp provider_config(config), do: config["config"] || %{}

  defp hmac_hex(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
end
