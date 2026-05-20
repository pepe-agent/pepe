defmodule Pepe.Webhooks.Discord do
  @moduledoc """
  Discord provider over the **Interactions** endpoint (slash commands), so it fits the
  inbound-webhook gateway rather than a persistent gateway connection. Point the app's
  "Interactions Endpoint URL" at `/webhooks/:company/discord/:slug` and add a slash
  command with a text option (e.g. `/ask prompt:...`).

  A connection's `"config"` holds:

    * `public_key`     - the app's public key, for the required Ed25519 signature check
    * `application_id` - used to post the follow-up answer

  Discord requires a synchronous ack within 3s, so a command is answered with a deferred
  response and the real reply is posted as a follow-up once the agent finishes.
  """
  @behaviour Pepe.Webhooks.Provider

  @api "https://discord.com/api/v10"
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
        "label" => "Public key",
        "type" => "text",
        "hint" => "the app's Public Key (hex), for signature verification"
      },
      %{"key" => "application_id", "label" => "Application ID", "type" => "text", "hint" => "used to post the reply"}
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

  # The command's text is the first option value; the follow-up is addressed by the
  # interaction token, so carry it as `from`.
  @impl true
  def parse(%{"type" => @application_command, "token" => token} = p) do
    text = command_text(p["data"])

    if is_binary(text) and text != "" do
      {:ok, [%{from: token, text: text, id: p["id"]}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  defp command_text(%{"options" => [%{"value" => value} | _]}) when is_binary(value), do: value
  defp command_text(%{"name" => name}) when is_binary(name), do: name
  defp command_text(_), do: nil

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
