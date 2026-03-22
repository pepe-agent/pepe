# Chatwoot channel plugin for Pepe (a package: this file plus manifest.json).
#
# Install the package (a directory, a .tar.gz, or an http(s) URL to either):
#
#     mix pepe plugin install examples/plugins/chatwoot
#
# It registers a "chatwoot" webhook provider. Set Chatwoot up with an AgentBot whose
# outgoing webhook URL points at this connection:
#
#     https://YOUR_HOST/webhooks/<company>/chatwoot/<slug>
#
# Handoff is native: the agent only answers conversations Chatwoot marks "pending"
# (bot-owned). The moment a human agent takes the conversation (status "open"), Pepe
# goes quiet; when it returns to "pending", the agent resumes. No external glue needed.
defmodule Pepe.Plugins.Chatwoot do
  @behaviour Pepe.Webhooks.Provider

  require Logger

  alias Pepe.Config

  # Conversation statuses the bot owns and may answer. A human taking over flips the
  # conversation to "open", which falls outside this set, so the agent stops.
  @bot_statuses ["pending"]

  @impl true
  def name, do: "chatwoot"

  @impl true
  def label, do: "Chatwoot"

  @impl true
  def config_schema do
    [
      %{"key" => "base_url", "label" => "Chatwoot URL", "type" => "text", "hint" => "e.g. https://app.chatwoot.com or your self-hosted URL"},
      %{"key" => "account_id", "label" => "Account ID", "type" => "text", "hint" => "The numeric account id in your Chatwoot URL"},
      %{"key" => "api_token", "label" => "API access token", "type" => "secret", "hint" => "An AgentBot or agent access token; store as ${ENV_VAR}"}
    ]
  end

  # Chatwoot doesn't do a GET verification handshake.
  @impl true
  def verify(_config, _params), do: :error

  # Chatwoot webhooks aren't HMAC-signed by default; accept and flag when no secret is
  # configured, matching the WhatsApp provider's dev-friendly default.
  @impl true
  def authenticate(config, _raw_body, headers) do
    case Config.interpolate(provider_config(config)["webhook_secret"]) do
      secret when is_binary(secret) and secret != "" ->
        given = headers["x-chatwoot-signature"] || headers["x-webhook-signature"] || ""
        if Plug.Crypto.secure_compare(secret, given), do: :ok, else: :error

      _ ->
        Logger.warning("[chatwoot] no webhook_secret set; inbound is unverified")
        :ok
    end
  end

  # Only act on an incoming message in a bot-owned conversation. `from` is the Chatwoot
  # conversation id, so the reply goes back to the same conversation.
  @impl true
  def parse(%{"event" => "message_created"} = p) do
    incoming? = p["message_type"] in ["incoming", 0]
    status = get_in(p, ["conversation", "status"])
    conv_id = get_in(p, ["conversation", "id"]) || get_in(p, ["conversation", "display_id"])
    text = p["content"]

    if incoming? and status in @bot_statuses and is_binary(text) and text != "" and conv_id do
      {:ok, [%{from: to_string(conv_id), text: text, id: to_string(p["id"] || "")}]}
    else
      :ignore
    end
  end

  def parse(_payload), do: :ignore

  # Post an outgoing message back into the conversation via the Chatwoot API.
  @impl true
  def deliver(config, conversation_id, text) do
    pc = provider_config(config)
    base = String.trim_trailing(to_string(pc["base_url"] || ""), "/")
    account_id = pc["account_id"]
    token = Config.interpolate(pc["api_token"])

    cond do
      base == "" -> {:error, :no_base_url}
      is_nil(account_id) -> {:error, :no_account_id}
      is_nil(token) or token == "" -> {:error, :no_api_token}
      true -> post_message(base, account_id, conversation_id, token, text)
    end
  end

  defp post_message(base, account_id, conversation_id, token, text) do
    url = "#{base}/api/v1/accounts/#{account_id}/conversations/#{conversation_id}/messages"

    case Req.post(url,
           headers: [{"api_access_token", token}],
           json: %{"content" => text, "message_type" => "outgoing"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_config(config), do: config["config"] || %{}
end
