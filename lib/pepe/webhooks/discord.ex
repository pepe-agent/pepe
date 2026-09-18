defmodule Pepe.Webhooks.Discord do
  @moduledoc """
  Discord provider over the **Interactions** endpoint (slash commands), so it fits the
  inbound-webhook gateway rather than a persistent gateway connection. Point the app's
  "Interactions Endpoint URL" at `/webhooks/:project/discord/:slug` and add a slash
  command with a text option (e.g. `/ask prompt:...`).

  A connection's `"config"` holds:

    * `public_key`     - the app's public key, for the required Ed25519 signature check
    * `application_id` - used to post the follow-up answer

  Discord requires a synchronous ack within 3s, so a command is answered with a deferred
  response and the real reply is posted as a follow-up once the agent finishes.

  Files arrive through a command's ATTACHMENT option (`/ask file:...`): that is the only
  route an interactions endpoint has, since ordinary message attachments are delivered
  over the gateway websocket this provider deliberately doesn't hold open. A voice
  message recorded in Discord is an ordinary message, so it never reaches here either -
  attaching the clip to the command does. What does arrive is resolved to text at the
  door like any other channel's media (see `Pepe.Webhooks.Media`).
  """
  @behaviour Pepe.Webhooks.Provider
  use Gettext, backend: Pepe.Gettext

  @api "https://discord.com/api/v10"
  # Where an attachment's signed url may point. Anything else is not Discord's file, and
  # fetching it would make this endpoint a proxy for whoever wrote the payload.
  @cdn_hosts ~w(cdn.discordapp.com media.discordapp.net)
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
  Fetch an attachment off Discord's CDN. The url arrives in the interaction payload,
  which is Ed25519-signed and already verified by `authenticate/3`, and is itself signed
  and short-lived - but it is still a url from the wire, so the host is checked against
  Discord's own CDN before anything is fetched.
  """
  @impl true
  def fetch_media(_config, %{ref: url}) when is_binary(url) do
    with :ok <- cdn(url) do
      # `decode_body: false`: what is wanted is the bytes, not Req's reading of whatever
      # the content-type claims they are.
      case Req.get(url, decode_body: false, receive_timeout: 120_000) do
        {:ok, %{status: s, body: body}} when s in 200..299 and is_binary(body) -> {:ok, body}
        {:ok, %{status: s}} -> {:error, {:discord, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fetch_media(_config, _media), do: {:error, :no_attachment_url}

  defp cdn(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in @cdn_hosts -> :ok
      _ -> {:error, :bad_attachment_url}
    end
  end

  @impl true
  def deliver(config, token, text) do
    app_id = provider_config(config)["application_id"]

    if is_binary(app_id) and app_id != "" do
      url = "#{@api}/webhooks/#{app_id}/#{token}/messages"

      case Req.post(url, json: %{"content" => text}, receive_timeout: 15_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, {:discord, s, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_application_id}
    end
  end

  @impl true
  def deliver_file(config, token, path, caption) do
    app_id = provider_config(config)["application_id"]

    if is_binary(app_id) and app_id != "" do
      url = "#{@api}/webhooks/#{app_id}/#{token}/messages"

      parts = [{:"files[0]", {File.stream!(path), filename: Path.basename(path)}}]

      parts =
        if caption in [nil, ""],
          do: parts,
          else: [{:payload_json, Jason.encode!(%{"content" => caption})} | parts]

      case Req.post(url, form_multipart: parts, receive_timeout: 120_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: body}} -> {:error, {:discord, s, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_application_id}
    end
  end

  defp provider_config(config), do: config["config"] || %{}

  defp decode16(nil), do: :error
  defp decode16(hex), do: Base.decode16(hex, case: :lower)
end
