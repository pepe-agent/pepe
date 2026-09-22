defmodule Pepe.Webhooks.Discord do
  @moduledoc """
  Discord provider over the **Interactions** endpoint (slash commands), so it fits the
  inbound-webhook gateway rather than a persistent gateway connection. Point the app's
  "Interactions Endpoint URL" at `/webhooks/:project/discord/:slug` and add a slash
  command with a text option (e.g. `/ask prompt:...`).

  A connection's `"config"` holds:

    * `public_key`     - the app's public key, for the required Ed25519 signature check
    * `application_id` - used to post the follow-up answer
    * `receive_channel_messages`, `bot_token`, `require_mention` - ordinary messages over the
      gateway, described below

  Discord requires a synchronous ack within 3s, so a command is answered with a deferred
  response and the real reply is posted as a follow-up once the agent finishes.

  Files arrive through a command's ATTACHMENT option (`/ask file:...`): that is the only
  route an interactions endpoint has, since ordinary message attachments are delivered
  over the gateway websocket, which the endpoint itself does not hold open. What does
  arrive is resolved to text at the door like any other channel's media (see
  `Pepe.Webhooks.Media`).

  **Ordinary messages** - a channel message, a photo dropped in it, a voice message recorded
  in it, a direct message to the bot - come over the gateway instead. A connection opts in with
  `receive_channel_messages` and a `bot_token`; `Pepe.Gateways.Discord` then holds the socket
  open and feeds each message to `parse/1` below, in a payload shaped
  `%{"t" => "MESSAGE_CREATE", "d" => message, "bot_id" => id}`. In a server the bot answers
  when it is @mentioned or replied to (`require_mention` turns that off), in a DM always; the
  reply goes to the channel with the bot token, addressed as `"ch:<channel id>"` where an
  interaction's follow-up is addressed by its token. Attachments of the message, of the
  message it replies to, and of a message forwarded to the bot all count.

  Optional config: `max_attachment_mb` (see `Pepe.Webhooks.Media.max_bytes/1`).
  """
  @behaviour Pepe.Webhooks.Provider
  use Gettext, backend: Pepe.Gettext

  # Discord refuses a message over 2000 characters. A reply is cut a little under that, at a
  # line break where there is one, and sent as several messages in order.
  @message_limit 1_900

  # Where an attachment's signed url may point. Anything else is not Discord's file, and
  # fetching it would make this endpoint a proxy for whoever wrote the payload.
  @cdn_hosts ~w(cdn.discordapp.com media.discordapp.net)

  @doc "The REST base URL (`:discord_api` overrides it, which is how a test points at a stand-in)."
  def api, do: Application.get_env(:pepe, :discord_api, "https://discord.com/api/v10")

  @doc "Whether this connection asked for ordinary messages over the gateway."
  @spec gateway?(map()) :: boolean()
  def gateway?(entry), do: (entry["config"] || %{})["receive_channel_messages"] == "true"

  @ping 1
  @application_command 2
  @pong ~s({"type":1})
  @deferred ~s({"type":5})

  @impl true
  def name, do: "discord"

  @impl true
  def label, do: "Discord"

  @impl true
  def config_schema do
    [
      %{
        "key" => "public_key",
        "label" => dgettext("webhooks", "Public key"),
        "type" => "text",
        "hint" => dgettext("webhooks", "the app's Public Key (hex), for signature verification")
      },
      %{
        "key" => "application_id",
        "label" => dgettext("webhooks", "Application ID"),
        "type" => "text",
        "hint" => dgettext("webhooks", "used to post the reply")
      },
      %{
        "key" => "receive_channel_messages",
        "label" => dgettext("webhooks", "Receive channel messages"),
        "type" => "select",
        # Opt-in: the first option is what a select starts on, and a new connection must not
        # start reading every message it can see.
        "options" => ["false", "true"],
        "hint" =>
          dgettext(
            "webhooks",
            "also answer ordinary messages, attachments and voice messages in channels and direct messages, not only slash commands; needs the bot token below"
          )
      },
      %{
        "key" => "bot_token",
        "label" => dgettext("webhooks", "Bot token"),
        "type" => "secret",
        "required" => false,
        "hint" =>
          dgettext(
            "webhooks",
            "only for channel messages: the bot's token from the app's Bot page, with the Message Content intent enabled there to read every message; store as ${ENV_VAR}"
          )
      },
      %{
        "key" => "require_mention",
        "label" => dgettext("webhooks", "Require mention in channels"),
        "type" => "select",
        "options" => ["true", "false"],
        "hint" =>
          dgettext(
            "webhooks",
            "in a server channel, reply only when the bot is @mentioned or replied to (default true); a direct message always replies"
          )
      },
      %{
        "key" => "max_attachment_mb",
        "label" => dgettext("webhooks", "Largest attachment (MB)"),
        "type" => "text",
        "required" => false,
        "hint" =>
          dgettext(
            "webhooks",
            "optional, 1 to 100: the largest file taken in from a message (default 20). Discord's own limit still applies"
          )
      }
    ]
  end

  @impl true
  def verify(_config, _params), do: :error

  # Ed25519: verify the signature over `timestamp + rawBody` with the app public key.
  @impl true
  def authenticate(config, raw_body, headers) do
    key = provider_config(config)["public_key"]
    sig = headers["x-signature-ed25519"]
    ts = headers["x-signature-timestamp"]

    with true <- is_binary(key) and key != "",
         {:ok, sig_bin} <- decode16(sig),
         {:ok, key_bin} <- decode16(key),
         true <- :crypto.verify(:eddsa, :none, "#{ts}#{raw_body}", sig_bin, [key_bin, :ed25519]) do
      :ok
    else
      false when key in [nil, ""] ->
        Pepe.Webhooks.Provider.unsigned_inbound("discord")

      _ ->
        :error
    end
  end

  # PING -> PONG; a slash command -> deferred ack (and run the agent for the follow-up).
  @impl true
  def respond(_config, %{"type" => @ping}, _headers), do: {:reply, 200, "application/json", @pong}

  def respond(_config, %{"type" => @application_command}, _headers),
    do: {:reply_async, 200, "application/json", @deferred}

  def respond(_config, _payload, _headers), do: :cont

  # The command's text is its first string option; the follow-up is addressed by the
  # interaction token, so carry it as `from`. An attachment option (type 11) rides along
  # as `:media`, and is enough on its own: `/ask file:<voice note>` with nothing typed is
  # still a message, it just has no caption.
  @impl true
  def parse(%{"t" => "MESSAGE_CREATE", "d" => %{} = d} = payload), do: parse_message(d, payload["bot_id"])

  def parse(%{"type" => @application_command, "token" => token} = p) do
    data = p["data"] || %{}
    media = attachment(data)
    text = command_text(data, attachment_ids(data), media)

    cond do
      is_binary(text) and text != "" ->
        {:ok, [message(token, p, text, media)]}

      media ->
        {:ok, [message(token, p, "", media)]}

      true ->
        :ignore
    end
  end

  def parse(_payload), do: :ignore

  defp message(token, p, text, media),
    do: %{from: token, text: text, id: p["id"], name: interaction_username(p), media: media}

  # A message from the gateway. `from` is the channel (`"ch:<id>"`), so everyone in a server
  # channel shares one conversation, the way a group chat does elsewhere; `sender_id` is the
  # person, which is what the allowlist and the trainer rules are about. The bot's own
  # @mention is dropped from the text so `@bot /new` reads as the command it is.
  defp parse_message(d, bot_id) do
    text = d |> Map.get("content") |> to_string() |> strip_mention(bot_id) |> String.trim()
    media = message_media(d)

    if text == "" and media == [] do
      :ignore
    else
      author = d["author"] || %{}

      {:ok,
       [
         %{
           from: "ch:" <> to_string(d["channel_id"]),
           text: text,
           id: d["id"],
           name: get_in(d, ["member", "nick"]) || author["global_name"] || author["username"],
           sender_id: author["id"],
           media: media
         }
       ]}
    end
  end

  defp strip_mention(text, bot_id) when is_binary(bot_id) and bot_id != "",
    do: String.replace(text, ~r/^\s*<@!?#{Regex.escape(bot_id)}>\s*/, "")

  defp strip_mention(text, _bot_id), do: text

  # The files that belong to this message: its own, those of the message it replies to (a
  # voice note answered with "what does this say?"), and those of a message forwarded to the
  # bot (which Discord delivers as a snapshot, not as attachments of the forward itself).
  defp message_media(d) do
    snapshots = for s <- List.wrap(d["message_snapshots"]), is_map(s["message"]), do: s["message"]
    replied = List.wrap(d["referenced_message"])

    [d | replied ++ snapshots]
    |> Enum.flat_map(fn m -> attachments(m) ++ stickers(m) end)
    |> Enum.uniq_by(& &1.ref)
  end

  defp attachments(m) do
    for a <- List.wrap(m["attachments"]), is_binary(a["url"]) do
      %{kind: kind(a["content_type"], a["filename"]), ref: a["url"], filename: a["filename"], mime: a["content_type"], size: a["size"]}
    end
  end

  # A sticker is a file on Discord's CDN like any other, except the Lottie kind, which is
  # an animation description rather than a picture and has nothing a model could look at.
  @sticker_formats %{1 => {"png", "image/png"}, 2 => {"png", "image/png"}, 4 => {"gif", "image/gif"}}

  defp stickers(m) do
    for s <- List.wrap(m["sticker_items"]),
        {ext, mime} <- List.wrap(@sticker_formats[s["format_type"]]),
        is_binary(s["id"]) and Regex.match?(~r/\A\d+\z/, s["id"]) do
      %{
        kind: "sticker",
        ref: "https://media.discordapp.net/stickers/#{s["id"]}.#{ext}",
        filename: "sticker-#{s["id"]}.#{ext}",
        mime: mime,
        size: nil
      }
    end
  end

  # A direct message always reaches the agent. In a server channel the bot answers when it is
  # @mentioned, or when the message replies to something it said; `require_mention: false`
  # opens the channel up. A slash command (an interaction) is addressed by definition.
  @impl true
  def addressed?(config, %{"t" => "MESSAGE_CREATE", "d" => d} = payload) do
    bot_id = payload["bot_id"]

    is_nil(d["guild_id"]) or mentioned?(d, bot_id) or replied_to?(d, bot_id) or
      provider_config(config)["require_mention"] == "false"
  end

  def addressed?(_config, _payload), do: true

  defp mentioned?(d, bot_id), do: is_binary(bot_id) and Enum.any?(List.wrap(d["mentions"]), &(&1["id"] == bot_id))
  defp replied_to?(d, bot_id), do: is_binary(bot_id) and get_in(d, ["referenced_message", "author", "id"]) == bot_id

  # A guild interaction carries the invoking member under `member.user`; a DM (no guild)
  # carries it straight under `user` instead - only one of the two is ever present.
  defp interaction_username(p), do: get_in(p, ["member", "user", "username"]) || get_in(p, ["user", "username"])

  # The first option whose value is actually text. An attachment option carries a
  # snowflake id in the same `value` field, which is not the user's prompt and must never
  # be read as one - so the attachment's own id is excluded explicitly, and a typed
  # option is preferred by its declared type (3 = STRING) where the payload states it.
  defp command_text(%{"options" => [_ | _] = options} = data, skip, media) do
    Enum.find_value(options, fn option ->
      value = option["value"]
      text? = is_binary(value) and value != "" and value not in skip and option["type"] in [nil, 3]
      if text?, do: value
    end) || fallback_text(data, media)
  end

  defp command_text(data, _skip, media), do: fallback_text(data, media)

  defp attachment_ids(%{"resolved" => %{"attachments" => atts}}) when is_map(atts), do: Map.keys(atts)
  defp attachment_ids(_data), do: []

  # Nothing was typed. With an attachment that is fine (the file is the message); without
  # one, the bare command name is all there is to go on, as before.
  defp fallback_text(_data, media) when not is_nil(media), do: nil
  defp fallback_text(%{"name" => name}, _media) when is_binary(name), do: name
  defp fallback_text(_data, _media), do: nil

  # A slash command's ATTACHMENT option (type 11) puts the file under
  # `data.resolved.attachments`, keyed by the id its option carries as a value. Taken in
  # option order, so `/ask prompt:... file:...` picks the file the user actually attached
  # rather than whatever the map happens to iterate first.
  #
  # This is the *only* way a file reaches an interactions endpoint: Discord sends message
  # attachments over the gateway (a websocket), which this provider deliberately isn't.
  defp attachment(%{"resolved" => %{"attachments" => atts}} = data) when is_map(atts) and atts != %{} do
    ids = for o <- List.wrap(data["options"]), is_binary(o["value"]), do: o["value"]
    picked = Enum.find_value(ids, &atts[&1]) || atts |> Map.values() |> List.first()

    case picked do
      %{"url" => url} when is_binary(url) ->
        %{
          kind: kind(picked["content_type"], picked["filename"]),
          ref: url,
          filename: picked["filename"],
          mime: picked["content_type"],
          size: picked["size"]
        }

      _ ->
        nil
    end
  end

  defp attachment(_data), do: nil

  defp kind(type, filename) do
    case to_string(type || MIME.from_path(to_string(filename))) do
      "audio/" <> _ -> "audio"
      "image/" <> _ -> "image"
      "video/" <> _ -> "video"
      _ -> "document"
    end
  end

  @doc """
  Fetch an attachment off Discord's CDN. The url comes off the wire (an interaction's payload
  is Ed25519-signed and already verified by `authenticate/3`, a gateway message came over the
  bot's own authenticated socket), and is itself signed and short-lived - but it is still a
  url from the wire, so the host is checked against Discord's own CDN before anything is
  fetched, and the transfer is cut at the connection's size limit.
  """
  @impl true
  def fetch_media(config, %{ref: url} = media) when is_binary(url) do
    with :ok <- Pepe.Webhooks.Media.within_cap(media[:size], config) do
      case Pepe.Webhooks.Media.Download.get(url, hosts: @cdn_hosts, max_bytes: Pepe.Webhooks.Media.max_bytes(config)) do
        {:error, :bad_url} -> {:error, :bad_attachment_url}
        result -> result
      end
    end
  end

  def fetch_media(_config, _media), do: {:error, :no_attachment_url}

  # `"ch:<channel id>"` is a message to a channel, sent with the bot's token; anything else
  # is an interaction token, and the reply is that interaction's follow-up.
  @impl true
  def deliver(config, "ch:" <> channel, text) do
    with {:ok, token} <- bot_token(config) do
      each_chunk(text, fn part ->
        post_channel(channel, token, json: %{"content" => part, "allowed_mentions" => %{"parse" => []}})
      end)
    end
  end

  def deliver(config, token, text) do
    with {:ok, app_id} <- application_id(config) do
      each_chunk(text, fn part ->
        post(followup_url(app_id, token), json: %{"content" => part}, receive_timeout: 15_000)
      end)
    end
  end

  @impl true
  def deliver_file(config, "ch:" <> channel, path, caption) do
    with {:ok, token} <- bot_token(config) do
      parts = file_parts(path, caption, %{"allowed_mentions" => %{"parse" => []}})
      post_channel(channel, token, form_multipart: parts, receive_timeout: 120_000)
    end
  end

  def deliver_file(config, token, path, caption) do
    with {:ok, app_id} <- application_id(config) do
      post(followup_url(app_id, token), form_multipart: file_parts(path, caption, %{}), receive_timeout: 120_000)
    end
  end

  defp each_chunk(text, send_one) do
    Enum.reduce_while(chunks(text), :ok, fn part, :ok ->
      case send_one.(part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp file_parts(path, caption, extra) do
    parts = [{:"files[0]", {File.stream!(path), filename: Path.basename(path)}}]
    payload = if caption in [nil, ""], do: extra, else: Map.put(extra, "content", caption)
    if payload == %{}, do: parts, else: [{:payload_json, Jason.encode!(payload)} | parts]
  end

  defp followup_url(app_id, token), do: "#{api()}/webhooks/#{app_id}/#{token}/messages"

  defp application_id(config) do
    case provider_config(config)["application_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :no_application_id}
    end
  end

  defp bot_token(config) do
    case Pepe.Config.interpolate(provider_config(config)["bot_token"]) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_bot_token}
    end
  end

  defp post_channel(channel, token, opts) do
    url = "#{api()}/channels/#{channel}/messages"
    post(url, [headers: [{"authorization", "Bot " <> token}], receive_timeout: 15_000] ++ opts)
  end

  # Discord answers a burst with 429 and says how long to wait; a reply that is worth sending
  # is worth waiting a few seconds for, twice at most, and no longer than that.
  @max_retry_wait_ms 10_000

  defp post(url, opts, retries \\ 2) do
    case Req.post(url, opts) do
      {:ok, %{status: s}} when s in 200..299 ->
        :ok

      {:ok, %{status: 429, body: body}} when retries > 0 ->
        Process.sleep(retry_after_ms(body))
        post(url, opts, retries - 1)

      {:ok, %{status: s, body: body}} ->
        {:error, {:discord, s, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_after_ms(%{"retry_after" => seconds}) when is_number(seconds),
    do: seconds |> Kernel.*(1_000) |> ceil() |> min(@max_retry_wait_ms) |> max(0)

  defp retry_after_ms(_body), do: 1_000

  @doc """
  Cut a reply into messages Discord will accept (2000 characters each), at a line break where
  there is one. A code fence that a cut lands inside is closed at the end of one message and
  reopened at the start of the next, so each renders as code instead of leaving the rest of
  the conversation in a stray block.
  """
  @spec chunks(String.t()) :: [String.t()]
  def chunks(text) do
    text = to_string(text)
    if String.length(text) <= @message_limit, do: [text], else: split(text, false, [])
  end

  # `open?` is whether the previous message ended inside a code fence.
  defp split(text, open?, acc) do
    prefix = if open?, do: "```\n", else: ""
    room = @message_limit - String.length(prefix) - 4

    if String.length(text) <= room do
      Enum.reverse([prefix <> text | acc])
    else
      {piece, rest} = cut(text, room)
      piece = prefix <> piece
      # The reopening line counts as a fence of its own, so an odd total means this piece
      # ends inside one.
      open_after? = rem(fences(piece), 2) == 1
      piece = if open_after?, do: piece <> "\n```", else: piece
      split(rest, open_after?, [piece | acc])
    end
  end

  defp fences(text), do: text |> String.split("```") |> length() |> Kernel.-(1)

  # Prefer the last line break in the window, unless that would leave a very short message.
  defp cut(text, room) do
    head = String.slice(text, 0, room)

    at =
      case :binary.matches(head, "\n") do
        [] ->
          room

        matches ->
          {offset, _} = List.last(matches)
          line_end = head |> binary_part(0, offset) |> String.length()
          if line_end >= div(room, 2), do: line_end, else: room
      end

    {String.slice(text, 0, at), text |> String.slice(at, String.length(text)) |> String.trim_leading("\n")}
  end

  defp provider_config(config), do: config["config"] || %{}

  defp decode16(nil), do: :error
  defp decode16(hex), do: Base.decode16(hex, case: :lower)
end
