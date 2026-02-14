defmodule Cortex.Config.Model do
  @moduledoc """
  A model *connection* — everything needed to talk to an OpenAI-compatible
  chat-completions endpoint: a base URL, an API key, the upstream model id and a
  few generation knobs.

  All providers that speak the OpenAI Chat Completions protocol work out of the
  box: OpenAI, OpenRouter, Together, Groq, Mistral, DeepSeek, Ollama, LM Studio,
  vLLM, llama.cpp, Nous Portal, z.ai/GLM, Kimi/Moonshot, MiniMax, NovitaAI, ...
  """

  @derive Jason.Encoder
  defstruct name: nil,
            base_url: "https://api.openai.com/v1",
            api_key: nil,
            model: nil,
            api: "openai-completions",
            max_tokens: nil,
            temperature: nil,
            context_window: nil,
            # Billing: price per 1M tokens, in the operator's configured currency.
            # nil means "unpriced" — usage is still counted, just not costed.
            input_price: nil,
            output_price: nil,
            headers: %{},
            # Ordered failover chain: names of other model connections to try when
            # this one errors transiently (rate limit, 5xx, network).
            fallbacks: [],
            # OAuth/subscription metadata when signed in via `Cortex.OAuth`
            # (%{"provider", "refresh", "expires_at", "token_url", "client_id"}).
            # `api_key` still holds the current access token (Bearer).
            oauth: nil

  @type t :: %__MODULE__{}

  @doc "Build a Model struct from a string-keyed map (as loaded from JSON)."
  def from_map(map) when is_map(map) do
    %__MODULE__{
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
      headers: map["headers"] || %{},
      fallbacks: map["fallbacks"] || [],
      oauth: map["oauth"]
    }
  end

  @doc """
  Resolve the API key, interpolating `${ENV_VAR}` references against the
  environment. Returns nil when unset.
  """
  def resolved_api_key(%__MODULE__{api_key: key}), do: Cortex.Config.interpolate(key)

  @doc "Resolve custom headers, interpolating any `${ENV_VAR}` in values."
  def resolved_headers(%__MODULE__{headers: headers}) do
    Map.new(headers || %{}, fn {k, v} -> {to_string(k), Cortex.Config.interpolate(v)} end)
  end
end
