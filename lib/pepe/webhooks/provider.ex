defmodule Pepe.Webhooks.Provider do
  @moduledoc """
  The contract an inbound-webhook integration implements - WhatsApp today, others
  (Instagram, Stripe, ...) later. Each provider is one module; `Pepe.Webhooks`
  dispatches to it, so adding a channel is a new module in the registry, not a new
  route.

  A connection's config map (from `Pepe.Config` `"webhooks"`) is passed to every
  callback. Provider-specific credentials live under its `"config"` key.
  """

  @typedoc """
  A normalized inbound message, provider-agnostic. `name`, when the platform's payload
  carries a sender display name at no extra cost (a WhatsApp contact profile, a Google
  Chat sender, a Teams activity's `from`, a Discord interaction's invoking member/user),
  is threaded through to the run's trace as a nicer `user.id` than `from` alone - `from`
  itself is often a conversation/channel address, not a per-person one (see each
  provider's own `parse/1`). `nil` for a provider whose payload has no such name.
  """
  @type inbound :: %{
          required(:from) => String.t(),
          required(:text) => String.t(),
          required(:id) => String.t() | nil,
          optional(:name) => String.t() | nil
        }

  @doc """
  The provider's registry name, e.g. `\"whatsapp\"`. This is the `:provider` segment of
  the webhook URL and the key a plugin provider is registered under.
  """
  @callback name() :: String.t()

  @doc "A human label for the dashboard (defaults to `name/0` when not given)."
  @callback label() :: String.t()

  @doc """
  Fields the dashboard should render to configure a connection to this provider, each a
  map like `%{\"key\" => \"api_token\", \"label\" => \"API token\", \"type\" => \"secret\"}`.
  `type` is one of `\"text\"`, `\"secret\"`, `\"select\"` (with `\"options\"`). Providers
  configured only from the CLI can omit this.
  """
  @callback config_schema() :: [map()]

  @doc """
  Answer the provider's verification handshake (a `GET` when the webhook URL is
  registered). Return `{:ok, challenge_to_echo}` when it checks out, `:error`
  otherwise. Providers without a handshake return `:error`.
  """
  @callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error

  @doc """
  Authenticate an inbound `POST`: verify its signature against the connection's
  secret using the raw request body and headers. `:ok` to accept, `:error` to
  reject (the request is dropped). When no secret is configured, fall back to
  `unsigned_inbound/1` rather than returning `:ok` outright - it accepts only in
  development and refuses everywhere else.
  """
  @callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error

  require Logger

  @doc """
  The fallback for an inbound `POST` when the connection has no secret to verify against.
  Accepting an unsigned request is a convenience for local development only; anywhere else it is
  refused, so a tenant that forgot to configure its signing secret cannot be impersonated by
  forged, unsigned events. Returns `:ok` in the `:dev` environment (with a warning), `:error`
  otherwise.
  """
  @spec unsigned_inbound(String.t()) :: :ok | :error
  def unsigned_inbound(provider) do
    if Application.get_env(:pepe, :env) == :dev do
      Logger.warning("[#{provider}] no secret set; accepting UNVERIFIED inbound (dev only)")
      :ok
    else
      Logger.error("[#{provider}] no secret configured; refusing unsigned inbound")
      :error
    end
  end

  @doc """
  Normalize a decoded payload into zero or more inbound messages. `:ignore` for
  payloads with nothing to act on (delivery receipts, status updates, ...).
  """
  @callback parse(payload :: map()) :: {:ok, [inbound()]} | :ignore

  @doc "Send a text message back to `to` (a provider address, e.g. a phone number)."
  @callback deliver(config :: map(), to :: String.t(), text :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Optional: produce a **synchronous** HTTP response to an inbound `POST`, for providers
  whose protocol needs one before any agent work (Slack's `url_verification` challenge,
  Discord's interaction `PING` and deferred acknowledgement). Return
  `{:reply, status, content_type, body}` to answer immediately (no agent run this call),
  or `:cont` to fall through to `parse/1` and the normal async flow. A provider that
  never needs this can omit it.
  """
  @callback respond(config :: map(), payload :: map(), headers :: map()) ::
              {:reply, non_neg_integer(), String.t(), String.t()} | :cont

  @doc """
  Optional: send a local file to `to` as an attachment/document, with an optional
  caption. A provider whose platform can't receive files can omit it (the `send_file`
  tool then reports the channel doesn't support attachments).
  """
  @callback deliver_file(config :: map(), to :: String.t(), path :: String.t(), caption :: String.t() | nil) ::
              :ok | {:error, term()}

  @doc """
  Optional: does this inbound payload address the bot, so it should be answered?
  Checked before `parse/1` runs. A provider whose platform supports group/channel
  conversations implements this to honor the connection's `require_mention` setting
  (native mention detection, e.g. Slack's `app_mention` event or Teams' mention
  entities - default when unset is `true`, reply only when mentioned or in a 1:1
  DM). A provider that is always 1:1, or hasn't added gating yet, can omit it
  (default: always addressed, today's behavior).
  """
  @callback addressed?(config :: map(), payload :: map()) :: boolean()

  @doc """
  Optional: send structured content (see `Pepe.Presentation`) rendered into this
  platform's own native UI - Slack Block Kit, Discord embeds/components, a table drawn
  as monospace text, whatever the platform actually supports. A provider that can't
  render structure, or hasn't added support yet, can omit this entirely -
  `Pepe.Webhooks.deliver_blocks/4` flattens the blocks to plain text
  (`Pepe.Presentation.to_text/1`) and sends the result through `deliver/3` instead, so a
  tool that emits blocks still works, just without the native rendering.
  """
  @callback deliver_blocks(config :: map(), to :: String.t(), blocks :: [Pepe.Presentation.block()]) ::
              :ok | {:error, term()}

  @optional_callbacks label: 0, config_schema: 0, respond: 3, deliver_file: 4, addressed?: 2, deliver_blocks: 3
end
