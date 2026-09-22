defmodule Pepe.Webhooks.WhatsApp do
  @moduledoc """
  WhatsApp Cloud API (Meta) provider. Inbound arrives as webhook `POST`s; outbound
  goes to the Graph API. A connection's `"config"` holds:

    * `phone_number_id` - the sending endpoint id
    * `access_token`    - Bearer token (write as `${ENV_VAR}`)
    * `app_secret`      - for the `X-Hub-Signature-256` check (write as `${ENV_VAR}`)
    * `verify_token`    - echoed back during the subscribe handshake

  Note the Cloud API's 24-hour rule: free-form replies are only allowed within 24h
  of the user's last message. Reactive support fits; proactive sends outside the
  window need pre-approved templates (not handled here).

  Inbound media (a voice note, a photo, a PDF) arrives as a media id rather than as
  bytes: it is described by `parse/1` and fetched later by `fetch_media/2`, which
  resolves the id to a short-lived download url and pulls it with the same token. What
  reaches the agent is the transcript, the document text, or the image itself - see
  `Pepe.Webhooks.Media`.
  """
  @behaviour Pepe.Webhooks.Provider
  use Gettext, backend: Pepe.Gettext

  alias Pepe.Config

  @graph "https://graph.facebook.com/v21.0"

  # Inbound message types that carry a file, each under a key of the same name holding a
  # media `id` (plus `mime_type`, and `filename` on a document, `caption` on the rest).
  @media_types ~w(audio voice image video document sticker)

  # Meta's media ids are opaque tokens of letters, digits and a few separators. One is put
  # into a Graph URL, so anything else in that position is not an id and is not sent.
  @media_id ~r/\A[A-Za-z0-9._-]{1,200}\z/

  @impl true
  def name, do: "whatsapp"

  @impl true
  def label, do: "WhatsApp (Meta Cloud API)"

  @impl true
  def config_schema do
    [
      %{
        "key" => "phone_number_id",
        "label" => dgettext("webhooks", "Phone number ID"),
        "type" => "text",
        "hint" => dgettext("webhooks", "the sending endpoint id from Meta")
      },
      %{
        "key" => "access_token",
        "label" => dgettext("webhooks", "Access token"),
        "type" => "secret",
        "hint" => dgettext("webhooks", "Graph API bearer token; store as ${ENV_VAR}")
      },
      %{
        "key" => "app_secret",
        "label" => dgettext("webhooks", "App secret"),
        "type" => "secret",
        "hint" => dgettext("webhooks", "verifies the inbound X-Hub-Signature-256; store as ${ENV_VAR}")
      },
      %{
        "key" => "verify_token",
        "label" => dgettext("webhooks", "Verify token"),
        "type" => "text",
        "hint" => dgettext("webhooks", "any string you choose; echoed during the subscribe handshake")
      },
      %{
        "key" => "max_attachment_mb",
        "label" => dgettext("webhooks", "Largest attachment (MB)"),
        "type" => "text",
        "required" => false,
        "hint" =>
          dgettext(
            "webhooks",
            "optional, 1 to 100: the largest file taken in from a message (default 20). Meta's own limit still applies"
          )
      }
    ]
  end

  @impl true
  def verify(config, params) do
    token = provider_config(config)["verify_token"]

    if is_binary(token) and params["hub.verify_token"] == token and params["hub.challenge"] do
      {:ok, to_string(params["hub.challenge"])}
    else
      :error
    end
  end

  @impl true
  def authenticate(config, raw_body, headers) do
    case Config.interpolate(provider_config(config)["app_secret"]) do
      secret when is_binary(secret) and secret != "" ->
        expected = "sha256=" <> hmac_hex(secret, raw_body)
        given = headers["x-hub-signature-256"] || ""
        if Plug.Crypto.secure_compare(expected, given), do: :ok, else: :error

      _ ->
        Pepe.Webhooks.Provider.unsigned_inbound("whatsapp")
    end
  end

  @impl true
  def parse(payload) do
    messages =
      payload
      |> Map.get("entry", [])
      |> List.wrap()
      |> Enum.flat_map(fn e -> List.wrap(e["changes"]) end)
      |> Enum.flat_map(fn c -> Enum.map(List.wrap(get_in(c, ["value", "messages"])), &{&1, contact_names(c)}) end)
      |> Enum.flat_map(fn {m, names} -> normalize(m, names) end)

    if messages == [], do: :ignore, else: {:ok, messages}
  end

  # The Cloud API sends the sender's profile name alongside the message, in the same
  # change's `value.contacts` (keyed by `wa_id`, the same value `messages[].from` carries)
  # rather than on the message itself.
  defp contact_names(change) do
    change
    |> get_in(["value", "contacts"])
    |> List.wrap()
    |> Map.new(fn contact -> {contact["wa_id"], get_in(contact, ["profile", "name"])} end)
  end

  @impl true
  def deliver(config, to, text) do
    pc = provider_config(config)
    token = Config.interpolate(pc["access_token"])
    phone_id = pc["phone_number_id"]

    cond do
      is_nil(token) or token == "" ->
        {:error, :no_access_token}

      is_nil(phone_id) ->
        {:error, :no_phone_number_id}

      true ->
        body = %{
          "messaging_product" => "whatsapp",
          "to" => to,
          "type" => "text",
          "text" => %{"body" => text}
        }

        case Req.post("#{@graph}/#{phone_id}/messages",
               auth: {:bearer, token},
               json: body,
               receive_timeout: 15_000
             ) do
          {:ok, %{status: s}} when s in 200..299 -> :ok
          {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Live probe for `mix pepe doctor`: check the phone number id + token resolve."
  def probe(config) do
    pc = provider_config(config)
    token = Config.interpolate(pc["access_token"])
    phone_id = pc["phone_number_id"]

    with true <- is_binary(token) and token != "",
         true <- is_binary(phone_id),
         {:ok, %{status: s}} when s in 200..299 <-
           Req.get("#{@graph}/#{phone_id}", auth: {:bearer, token}, receive_timeout: 10_000) do
      :ok
    else
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_configured}
    end
  end

  # Text is the message. Media is a message too: the attachment is described here and
  # resolved to text later, off the request process (`Pepe.Webhooks.Media`), so a voice
  # note arrives as words and a PDF arrives with its contents. Statuses, reactions,
  # system events and the rest are still ignored.
  defp normalize(%{"from" => from, "type" => "text", "text" => %{"body" => body}} = m, names),
    do: [%{from: from, text: body, id: m["id"], name: names[from]}]

  defp normalize(%{"from" => from, "type" => type} = m, names) when type in @media_types do
    part = m[type] || %{}

    case part["id"] do
      id when is_binary(id) and id != "" ->
        media = %{
          kind: kind(type),
          ref: id,
          filename: part["filename"],
          mime: part["mime_type"],
          # The webhook payload never carries a size (only a sha256); it is read off the
          # media metadata in fetch_media/2 instead, before the bytes are pulled.
          size: nil
        }

        [%{from: from, text: part["caption"] || "", id: m["id"], name: names[from], media: media}]

      _ ->
        []
    end
  end

  # A shared location, a shared contact card and a tapped reply button are messages too:
  # each becomes one line of text, so the agent knows what the person meant without a
  # channel-specific tool. The fields are the sender's, so the line is cleaned like any
  # other outside text before it becomes part of a prompt.
  defp normalize(%{"from" => from, "type" => "location"} = m, names) do
    loc = m["location"] || %{}
    place = [loc["name"], loc["address"]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")
    coords = "#{loc["latitude"]}, #{loc["longitude"]}"
    line = if place == "", do: "(#{coords})", else: "#{place} (#{coords})"

    text_message(m, names, from, "[The user shared a location: #{line}]")
  end

  defp normalize(%{"from" => from, "type" => "contacts"} = m, names) do
    cards =
      m["contacts"]
      |> List.wrap()
      |> Enum.map_join("; ", fn c ->
        phones = c["phones"] |> List.wrap() |> Enum.map_join(", ", &(&1["phone"] || ""))
        String.trim("#{get_in(c, ["name", "formatted_name"])} #{phones}")
      end)

    text_message(m, names, from, "[The user shared a contact: #{cards}]")
  end

  defp normalize(%{"from" => from, "type" => "interactive"} = m, names) do
    reply = get_in(m, ["interactive", "button_reply"]) || get_in(m, ["interactive", "list_reply"]) || %{}
    tapped(m, names, from, reply["title"])
  end

  defp normalize(%{"from" => from, "type" => "button"} = m, names),
    do: tapped(m, names, from, get_in(m, ["button", "text"]))

  defp normalize(_, _names), do: []

  defp tapped(_m, _names, _from, title) when title in [nil, ""], do: []
  defp tapped(m, names, from, title), do: [%{from: from, text: title, id: m["id"], name: names[from]}]

  defp text_message(m, names, from, text),
    do: [%{from: from, text: Pepe.Security.ExternalContent.sanitize(text), id: m["id"], name: names[from]}]

  # A voice note and an uploaded audio file both just need transcribing, so both are
  # "audio" here - unlike Telegram, where the distinction buys a spoken reply back.
  # A sticker is a reaction rather than a question, so Pepe.Webhooks.Media only takes one
  # in when the model can look at it, and answers it briefly.
  defp kind("voice"), do: "audio"
  defp kind("audio"), do: "audio"
  defp kind("image"), do: "image"
  defp kind("video"), do: "video"
  defp kind("sticker"), do: "sticker"
  defp kind(_other), do: "document"

  @doc """
  Fetch an inbound attachment. Two steps, both authenticated: the media id resolves to a
  short-lived download url on the Graph API, and that url is then fetched with the same
  bearer token (Meta returns `401` without it).

  The url is never taken from the webhook payload - it comes back from an authenticated
  Graph call - so a crafted inbound event cannot point this at a host of its choosing.
  The scheme is still checked, and the declared size is honored before the transfer.
  """
  @impl true
  def fetch_media(config, %{ref: id}) when is_binary(id) do
    pc = provider_config(config)
    token = Config.interpolate(pc["access_token"])

    cond do
      not Regex.match?(@media_id, id) ->
        {:error, :bad_media_id}

      is_binary(token) and token != "" ->
        with {:ok, url, size} <- media_url(token, id),
             :ok <- Pepe.Webhooks.Media.within_cap(size, config) do
          download_media(url, token, config)
        end

      true ->
        {:error, :no_access_token}
    end
  end

  def fetch_media(_config, _media), do: {:error, :no_media_id}

  defp download_media(url, token, config) do
    case Pepe.Webhooks.Media.Download.get(url, bearer: token, max_bytes: Pepe.Webhooks.Media.max_bytes(config)) do
      {:error, :bad_url} -> {:error, :bad_media_url}
      result -> result
    end
  end

  # The metadata answer carries `file_size` alongside the url, which is the one chance to
  # refuse an oversized file before paying for it.
  defp media_url(token, id) do
    case Req.get("#{@graph}/#{id}", auth: {:bearer, token}, receive_timeout: 15_000) do
      {:ok, %{status: s, body: %{"url" => url} = body}} when s in 200..299 and is_binary(url) ->
        {:ok, url, body["file_size"]}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, b}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def deliver_file(config, to, path, caption) do
    pc = provider_config(config)
    token = Config.interpolate(pc["access_token"])
    phone_id = pc["phone_number_id"]

    cond do
      is_nil(token) or token == "" ->
        {:error, :no_access_token}

      is_nil(phone_id) ->
        {:error, :no_phone_number_id}

      true ->
        send_document(phone_id, token, to, path, caption)
    end
  end

  defp send_document(phone_id, token, to, path, caption) do
    with {:ok, media_id} <- upload_media(phone_id, token, path) do
      doc = document_payload(media_id, path, caption)
      body = %{"messaging_product" => "whatsapp", "to" => to, "type" => "document", "document" => doc}

      case Req.post("#{@graph}/#{phone_id}/messages", auth: {:bearer, token}, json: body, receive_timeout: 30_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp document_payload(media_id, path, caption) when caption in [nil, ""],
    do: %{"id" => media_id, "filename" => Path.basename(path)}

  defp document_payload(media_id, path, caption),
    do: %{"id" => media_id, "filename" => Path.basename(path), "caption" => caption}

  # Upload media to the Cloud API and return its media id (referenced when sending).
  defp upload_media(phone_id, token, path) do
    parts = [
      messaging_product: "whatsapp",
      type: MIME.from_path(path),
      file: {File.stream!(path), filename: Path.basename(path)}
    ]

    case Req.post("#{@graph}/#{phone_id}/media", auth: {:bearer, token}, form_multipart: parts, receive_timeout: 120_000) do
      {:ok, %{status: s, body: %{"id" => id}}} when s in 200..299 -> {:ok, id}
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_config(config), do: config["config"] || %{}

  defp hmac_hex(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
end
