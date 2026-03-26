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
  """
  @behaviour Pepe.Webhooks.Provider

  require Logger

  alias Pepe.Config

  @graph "https://graph.facebook.com/v21.0"

  @impl true
  def name, do: "whatsapp"

  @impl true
  def label, do: "WhatsApp (Meta Cloud API)"

  @impl true
  def config_schema do
    [
      %{"key" => "phone_number_id", "label" => "Phone number ID", "type" => "text", "hint" => "the sending endpoint id from Meta"},
      %{"key" => "access_token", "label" => "Access token", "type" => "secret", "hint" => "Graph API bearer token; store as ${ENV_VAR}"},
      %{
        "key" => "app_secret",
        "label" => "App secret",
        "type" => "secret",
        "hint" => "verifies the inbound X-Hub-Signature-256; store as ${ENV_VAR}"
      },
      %{
        "key" => "verify_token",
        "label" => "Verify token",
        "type" => "text",
        "hint" => "any string you choose; echoed during the subscribe handshake"
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
        # No app secret configured - accept but flag it (fine for local dev only).
        Logger.warning("[whatsapp] no app_secret set; inbound signature unverified")
        :ok
    end
  end

  @impl true
  def parse(payload) do
    messages =
      payload
      |> Map.get("entry", [])
      |> List.wrap()
      |> Enum.flat_map(fn e -> List.wrap(e["changes"]) end)
      |> Enum.flat_map(fn c -> List.wrap(get_in(c, ["value", "messages"])) end)
      |> Enum.flat_map(&normalize/1)

    if messages == [], do: :ignore, else: {:ok, messages}
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

  # Only text messages become a conversation turn; media/status/etc. are ignored
  # for now (the door is open to handle them like the Telegram media path later).
  defp normalize(%{"from" => from, "type" => "text", "text" => %{"body" => body}} = m),
    do: [%{from: from, text: body, id: m["id"]}]

  defp normalize(_), do: []

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
        with {:ok, media_id} <- upload_media(phone_id, token, path) do
          doc =
            %{"id" => media_id, "filename" => Path.basename(path)}
            |> then(fn d -> if caption in [nil, ""], do: d, else: Map.put(d, "caption", caption) end)

          body = %{"messaging_product" => "whatsapp", "to" => to, "type" => "document", "document" => doc}

          case Req.post("#{@graph}/#{phone_id}/messages", auth: {:bearer, token}, json: body, receive_timeout: 30_000) do
            {:ok, %{status: s}} when s in 200..299 -> :ok
            {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

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
