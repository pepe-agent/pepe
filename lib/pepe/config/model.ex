defmodule Pepe.Config.Model do
  @moduledoc """
  A model *connection* - everything needed to talk to an OpenAI-compatible
  chat-completions endpoint: a base URL, an API key, the upstream model id and a
  few generation knobs.

  All providers that speak the OpenAI Chat Completions protocol work out of the
  box: OpenAI, OpenRouter, Together, Groq, Mistral, DeepSeek, Ollama, LM Studio,
  vLLM, llama.cpp, Nous Portal, z.ai/GLM, Kimi/Moonshot, MiniMax, NovitaAI, ...
  """

  @derive Jason.Encoder
  defstruct id: nil,
            name: nil,
            base_url: "https://api.openai.com/v1",
            api_key: nil,
            model: nil,
            api: "openai-completions",
            max_tokens: nil,
            temperature: nil,
            context_window: nil,
            # Billing: price per 1M tokens, in the operator's configured currency.
            # nil means "unpriced" - usage is still counted, just not costed.
            input_price: nil,
            output_price: nil,
            # Price per 1M for input tokens the provider served from its prompt cache (much cheaper
            # than fresh input on OpenAI/Anthropic/DeepSeek). Optional manual override; when unset,
            # the layered price book supplies the cache rate, and failing that cached tokens are
            # priced as normal input (no worse than before). Only meaningful with `input_price`-style
            # metering, i.e. API-key connections.
            cached_input_price: nil,
            # When true, the runtime refuses to send to this provider unless the agent
            # runs a redaction hook - a hard guarantee that raw PII never reaches it.
            require_redaction: nil,
            # Enable the provider's own native web search (Responses/Codex models only): the
            # model searches the web itself, server-side, no separate search key or cost. Off by
            # default. Ignored by non-Responses adapters.
            web_search: false,
            # Whether this endpoint accepts image content parts (vision). When true, an inbound
            # image (e.g. a Telegram photo) is sent to the model as an image it can actually see,
            # instead of just a file path in the prompt. Off by default: not every OpenAI-compatible
            # endpoint accepts a content-array message, and sending one to a text-only model errors.
            vision: false,
            headers: %{},
            # Ordered failover chain: names of other model connections to try when
            # this one errors transiently (rate limit, 5xx, network).
            fallbacks: [],
            # OAuth/subscription metadata when signed in via `Pepe.OAuth`
            # (%{"provider", "refresh", "expires_at", "token_url", "client_id"}).
            # `api_key` still holds the current access token (Bearer).
            oauth: nil,
            # What this subscription costs per month, if it is one (ChatGPT Plus, Claude
            # Max). Only meaningful alongside `oauth`. Tokens spent on a subscription cost
            # nothing at the margin - the month was paid for in advance, whether you send
            # one message or ten thousand - so the ledger records them at zero and counts
            # this fixed figure once instead. Unset means "I have not told Pepe what I pay",
            # and the margin is then reported as the optimistic bound it really is.
            # See Pepe.Usage.
            monthly_cost: nil

  @type t :: %__MODULE__{}

  @doc """
  Whether this connection is a subscription (signed in with an account) rather than an API
  key billed by the token.

  It is the distinction the whole cost side of billing turns on: the same conversation costs
  real money on one and nothing at the margin on the other, while being worth exactly the
  same to the client either way.
  """
  @spec subscription?(t()) :: boolean()
  def subscription?(%__MODULE__{oauth: oauth}), do: is_map(oauth) and oauth != %{}

  @doc "Build a Model struct from a string-keyed map (as loaded from JSON)."
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      base_url: map["base_url"] || "https://api.openai.com/v1",
      api_key: map["api_key"],
      model: map["model"],
      api: map["api"] || "openai-completions",
      max_tokens: map["max_tokens"],
      temperature: map["temperature"],
      context_window: map["context_window"],
      input_price: map["input_price"],
      output_price: map["output_price"],
      cached_input_price: map["cached_input_price"],
      require_redaction: map["require_redaction"],
      web_search: map["web_search"] == true,
      vision: map["vision"] == true,
      headers: map["headers"] || %{},
      fallbacks: map["fallbacks"] || [],
      oauth: map["oauth"],
      monthly_cost: map["monthly_cost"]
    }
  end

  @doc """
  Resolve the API key, interpolating `${ENV_VAR}` references against the
  environment. Returns nil when unset.
  """
  def resolved_api_key(%__MODULE__{api_key: key}), do: Pepe.Config.interpolate(key)

  @doc "Resolve custom headers, interpolating any `${ENV_VAR}` in values."
  def resolved_headers(%__MODULE__{headers: headers}) do
    Map.new(headers || %{}, fn {k, v} -> {to_string(k), Pepe.Config.interpolate(v)} end)
  end
end
