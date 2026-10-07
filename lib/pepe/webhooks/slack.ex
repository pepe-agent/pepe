defmodule Pepe.Webhooks.Slack do
  @moduledoc """
  Slack provider (Events API). Inbound arrives as webhook `POST`s to
  `/webhooks/:project/slack/:slug`; replies go to the Web API `chat.postMessage`.

  A connection's `"config"` holds:

    * `bot_token`      - the bot user OAuth token (`xoxb-...`), the Bearer for replies
    * `signing_secret` - verifies the `X-Slack-Signature` on inbound requests

  Pictures and files sent to the bot are read like on any other channel (see
  `Pepe.Webhooks.Media`); that needs the `files:read` scope on the Slack app, and sending files back needs `files:write`. While the agent works on a
  message it carries an eyes reaction (`reactions:write`), and a reaction
  on one of the bot's own messages is told to the agent as feedback (`reactions:read`
  and the `reaction_added` event).

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
        "key" => "accept_bots",
        "label" => dgettext("webhooks", "Answer these bots and apps"),
        "type" => "text",
        "hint" =>
          dgettext(
            "webhooks",
            "Messages from other apps are ignored by default. To answer one (a help desk posting each new ticket, say), list its bot or app id, separated by commas. Ignored ones are logged with their ids."
          )
      },
      %{
        "key" => "reactions",
        "label" => dgettext("webhooks", "Learn from reactions"),
        "type" => "select",
        "options" => ["own", "off"],
        "option_labels" => %{
          "own" => dgettext("webhooks", "Only on the bot's own messages"),
          "off" => dgettext("webhooks", "Ignore reactions")
        },
        "hint" =>
          dgettext(
            "webhooks",
            "A 👍 or ❤️ on one of the bot's own messages is told to the agent as feedback. Choose Ignore reactions to turn that off."
          )
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
  def parse(%{"type" => "event_callback", "event" => %{"type" => "reaction_added"}} = payload),
    do: parse_reaction(payload)

  def parse(%{"type" => "event_callback", "event" => event} = payload) do
    if user_message?(payload, event) do
      {:ok, [message(event)]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # Someone reacting to a message the bot sent is feedback on its answer, handed to the agent
  # the same way Telegram does it: a turn that reads `[reacted 👍]`, which the agent learns from
  # by convention. Only the bot's own messages count (`item_user` is the author of the message
  # reacted to), so a 👍 on a colleague's message is never delivered, and neither is the bot's
  # own eyes reaction. The bot's user id comes from the payload's `authorizations`; without it
  # there is no telling whose message it was, so the reaction is dropped.
  defp parse_reaction(%{"event" => %{"item" => %{"type" => "message"} = item} = event} = payload) do
    emoji = reaction_emoji(event["reaction"])

    if bot_message?(payload, event) and emoji != "" do
      {:ok, [%{from: item["channel"], text: "[reacted #{emoji}]", id: event["event_ts"]}]}
    else
      :ignore
    end
  end

  defp parse_reaction(_payload), do: :ignore

  defp bot_message?(payload, event) do
    bot_id = payload |> Map.get("authorizations") |> List.wrap() |> Enum.find_value(& &1["user_id"])
    is_binary(bot_id) and event["item_user"] == bot_id and event["user"] != bot_id
  end

  # Slack names a reaction (`+1`, `heart`, with an optional `::skin-tone-3`); the agent is told
  # the emoji itself where it is a common one, and `:name:` where it is not.
  @emoji %{
    "+1" => "👍",
    "thumbsup" => "👍",
    "-1" => "👎",
    "thumbsdown" => "👎",
    "heart" => "❤️",
    "ok_hand" => "👌",
    "fire" => "🔥",
    "tada" => "🎉",
    "pray" => "🙏",
    "clap" => "👏",
    "raised_hands" => "🙌",
    "100" => "💯",
    "white_check_mark" => "✅",
    "x" => "❌"
  }

  defp reaction_emoji(name) when is_binary(name) do
    base = name |> String.split("::") |> hd()
    Map.get(@emoji, base) || if(base == "", do: "", else: ":#{base}:")
  end

  defp reaction_emoji(_name), do: ""

  # A real message: a message/app_mention event with text, attachments or a file, and not an
  # edit/join/etc. subtype (a message with an attachment arrives as `file_share`). One written
  # by a bot or integration is let through only to be marked (`:bot`, see `message/1`): the
  # shared webhook layer drops it unless the connection lists that app in `accept_bots`. This
  # app's own messages never get past here, whatever that list says, so the bot cannot be made
  # to answer itself.
  defp user_message?(payload, %{"type" => type} = event) when type in ["message", "app_mention"] do
    (text?(event) or attachments_text(event) != "" or media(event) != []) and
      event["subtype"] in [nil, "file_share", "bot_message"] and not own?(payload, event)
  end

  defp user_message?(_payload, _event), do: false

  defp message(event) do
    text = [strip_mention(event["text"] || ""), attachments_text(event)] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    base = %{from: event["channel"], text: text, id: event["ts"], media: media(event)}
    if from_bot?(event), do: Map.put(base, :bot, bot_ref(event)), else: base
  end

  defp from_bot?(event), do: is_binary(event["bot_id"]) or event["subtype"] == "bot_message"

  defp bot_ref(event), do: %{id: event["bot_id"], app: event["app_id"], name: event["username"] || get_in(event, ["bot_profile", "name"])}

  # A message this very app sent: same app id as the payload's own, or written by the bot's own
  # user.
  defp own?(payload, event) do
    own_app = payload["api_app_id"]
    own_user = payload |> Map.get("authorizations") |> List.wrap() |> Enum.find_value(& &1["user_id"])

    (is_binary(own_app) and event["app_id"] == own_app) or (is_binary(own_user) and event["user"] == own_user)
  end

  # What an integration puts in `attachments` (the coloured bar) instead of in `text`: a title,
  # a body and labelled fields. Zoho Desk, GitHub, monitoring tools: their whole message lives
  # here, so without it such a message reads as empty.
  defp attachments_text(event) do
    event["attachments"]
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&attachment_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp attachment_text(a) do
    fields = for f <- List.wrap(a["fields"]), is_map(f), do: "#{f["title"]}: #{f["value"]}"

    [a["pretext"], a["title"], a["text"] | fields]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n")
  end

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
  # channel is not addressed to the bot unless the channel was told otherwise with `/mention`
  # (set up both subscriptions, per the moduledoc, so a real mention always also arrives as
  # app_mention).
  @impl true
  def addressed?(_config, %{"type" => "event_callback", "event" => %{"type" => "app_mention"}}),
    do: true

  # A reaction needs no mention, only the connection's `reactions` setting not being off.
  def addressed?(config, %{"type" => "event_callback", "event" => %{"type" => "reaction_added"}}),
    do: provider_config(config)["reactions"] != "off"

  def addressed?(_config, %{"type" => "event_callback", "event" => %{"channel_type" => "im"}}),
    do: true

  def addressed?(_config, %{"type" => "event_callback", "event" => %{"type" => "message"} = event}) do
    String.starts_with?(event["channel"] || "", "D")
  end

  def addressed?(_config, _payload), do: true

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

  # Slack has no typing indicator for a bot, so the message being worked on gets an eyes
  # reaction while the agent is on it (needs `reactions:write`). Best effort: a missing scope
  # or an already-removed reaction is not worth more than a debug line.
  @impl true
  def working(config, %{from: channel, id: ts}, state) when is_binary(ts) do
    token = Config.interpolate(provider_config(config)["bot_token"])
    method = if state == :start, do: "reactions.add", else: "reactions.remove"

    if is_binary(token) and token != "" do
      with {:ok, _} <- api_post(token, method, %{"channel" => channel, "timestamp" => ts, "name" => "eyes"}), do: :ok
    else
      {:error, :no_bot_token}
    end
  end

  def working(_config, _message, _state), do: :ok

  # Slack retired `files.upload`; a file now goes in three steps: ask for an upload url,
  # send the bytes there, then complete the upload into the channel (needs `files:write`).
  @impl true
  def deliver_file(config, channel, path, caption) do
    token = Config.interpolate(provider_config(config)["bot_token"])
    name = Path.basename(path)

    with true <- (is_binary(token) and token != "") or {:error, :no_bot_token},
         {:ok, bytes} <- File.read(path),
         {:ok, %{"upload_url" => url, "file_id" => id}} <-
           api_get(token, "files.getUploadURLExternal", filename: name, length: byte_size(bytes)),
         :ok <- upload_bytes(url, bytes),
         {:ok, _} <- api_post(token, "files.completeUploadExternal", complete_body(id, name, channel, caption)) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp complete_body(id, name, channel, caption) do
    body = %{"files" => [%{"id" => id, "title" => name}], "channel_id" => channel}
    if caption in [nil, ""], do: body, else: Map.put(body, "initial_comment", caption)
  end

  defp upload_bytes(url, bytes) do
    case Req.post(url, body: bytes, headers: [{"content-type", "application/octet-stream"}], receive_timeout: 120_000) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: body}} -> {:error, {:slack, s, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_get(token, method, params),
    do: api_result(Req.get("#{@api}/#{method}", auth: {:bearer, token}, params: params, receive_timeout: 30_000))

  defp api_post(token, method, json),
    do: api_result(Req.post("#{@api}/#{method}", auth: {:bearer, token}, json: json, receive_timeout: 30_000))

  defp api_result({:ok, %{status: s, body: %{"ok" => true} = body}}) when s in 200..299, do: {:ok, body}
  defp api_result({:ok, %{status: s, body: body}}), do: {:error, {:slack, s, body}}
  defp api_result({:error, reason}), do: {:error, reason}

  defp provider_config(config), do: config["config"] || %{}

  defp hmac_hex(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
end
