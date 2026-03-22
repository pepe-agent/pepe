defmodule Pepe.Webhooks.Provider do
  @moduledoc """
  The contract an inbound-webhook integration implements - WhatsApp today, others
  (Instagram, Stripe, ...) later. Each provider is one module; `Pepe.Webhooks`
  dispatches to it, so adding a channel is a new module in the registry, not a new
  route.

  A connection's config map (from `Pepe.Config` `"webhooks"`) is passed to every
  callback. Provider-specific credentials live under its `"config"` key.
  """

  @typedoc "A normalized inbound message, provider-agnostic."
  @type inbound :: %{from: String.t(), text: String.t(), id: String.t() | nil}

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

  @optional_callbacks label: 0, config_schema: 0

  @doc """
  Answer the provider's verification handshake (a `GET` when the webhook URL is
  registered). Return `{:ok, challenge_to_echo}` when it checks out, `:error`
  otherwise. Providers without a handshake return `:error`.
  """
  @callback verify(config :: map(), params :: map()) :: {:ok, String.t()} | :error

  @doc """
  Authenticate an inbound `POST`: verify its signature against the connection's
  secret using the raw request body and headers. `:ok` to accept, `:error` to
  reject (the request is dropped). Providers may return `:ok` when no secret is
  configured, but should log that it's unverified.
  """
  @callback authenticate(config :: map(), raw_body :: binary(), headers :: map()) :: :ok | :error

  @doc """
  Normalize a decoded payload into zero or more inbound messages. `:ignore` for
  payloads with nothing to act on (delivery receipts, status updates, ...).
  """
  @callback parse(payload :: map()) :: {:ok, [inbound()]} | :ignore

  @doc "Send a text message back to `to` (a provider address, e.g. a phone number)."
  @callback deliver(config :: map(), to :: String.t(), text :: String.t()) ::
              :ok | {:error, term()}
end
