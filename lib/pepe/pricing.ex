defmodule Pepe.Pricing do
  @moduledoc """
  Model prices for billing, resolved in layers (most specific wins):

      manual price on the model connection   (operator typed it)
                 ▲
      live cache   ~/.pepe/data/price_book.json   (OpenRouter + LiteLLM, refreshed)
                 ▲
      built-in seed   (@seed below — an offline fallback, no network needed)

  Prices are **per 1,000,000 tokens** in the operator's currency. Provider rate
  cards change over time, so the seed is only a floor: `refresh/0` pulls current
  prices from OpenRouter's public `/models` and the community LiteLLM price map,
  writing a dated cache that layers on top. The manual per-model price always wins,
  so a wrong or missing lookup is never load-bearing.

  Lookups match by longest id substring, so `gpt-4o-2024-08-06` resolves to a
  `gpt-4o` entry and a dated snapshot inherits its family's price.
  """

  require Logger

  alias Pepe.Config

  @litellm_url "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  @openrouter_url "https://openrouter.ai/api/v1/models"

  # {input_per_1M, output_per_1M} in USD. Offline fallback only; refresh overlays it.
  @seed %{
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4o" => {2.50, 10.00},
    "gpt-4.1-mini" => {0.40, 1.60},
    "gpt-4.1-nano" => {0.10, 0.40},
    "gpt-4.1" => {2.00, 8.00},
    "gpt-4-turbo" => {10.00, 30.00},
    "gpt-3.5-turbo" => {0.50, 1.50},
    "o1-mini" => {1.10, 4.40},
    "o1" => {15.00, 60.00},
    "o3-mini" => {1.10, 4.40},
    "o3" => {2.00, 8.00},
    "o4-mini" => {1.10, 4.40},
    "claude-3-5-haiku" => {0.80, 4.00},
    "claude-3-5-sonnet" => {3.00, 15.00},
    "claude-3-7-sonnet" => {3.00, 15.00},
    "claude-3-haiku" => {0.25, 1.25},
    "claude-3-opus" => {15.00, 75.00},
    "claude-sonnet-4" => {3.00, 15.00},
    "claude-opus-4" => {15.00, 75.00},
    "claude-haiku-4" => {1.00, 5.00},
    "gemini-1.5-flash" => {0.075, 0.30},
    "gemini-1.5-pro" => {1.25, 5.00},
    "gemini-2.0-flash" => {0.10, 0.40},
    "gemini-2.5-pro" => {1.25, 10.00},
    "deepseek-chat" => {0.27, 1.10},
    "deepseek-reasoner" => {0.55, 2.19},
    "mistral-large" => {2.00, 6.00},
    "mistral-small" => {0.20, 0.60}
  }

  @doc "The built-in seed price map (offline fallback)."
  def seed, do: @seed

  @doc "Where the refreshed live price cache is written."
  def cache_path, do: Path.join([Config.home(), "data", "price_book.json"])

  @doc """
  Look up `{input_per_1M, output_per_1M}` for a model id, or `nil` if unknown.
  Pass a preloaded `cache` map (from `load_cache/0`) to avoid re-reading disk when
  pricing many entries; the 1-arity form loads it for you.
  """
  @spec lookup(String.t() | nil, map()) :: {number(), number()} | nil
  def lookup(nil, _cache), do: nil

  def lookup(model_id, cache) when is_binary(model_id) do
    id = String.downcase(model_id)
    longest_match(cache, id) || longest_match(@seed, id)
  end

  @spec lookup(String.t() | nil) :: {number(), number()} | nil
  def lookup(model_id), do: lookup(model_id, load_cache())

  # Longest key that is a substring of the id wins; value may be a tuple (seed) or
  # a %{"in", "out"} map (cache).
  defp longest_match(map, id) do
    map
    |> Enum.filter(fn {k, _} -> String.contains?(id, k) end)
    |> Enum.max_by(fn {k, _} -> String.length(k) end, fn -> nil end)
    |> case do
      {_k, {i, o}} -> {i, o}
      {_k, %{"in" => i, "out" => o}} -> {i, o}
      _ -> nil
    end
  end

  @doc "Load the cached live price map (`id => %{\"in\", \"out\"}`), or `%{}`."
  @spec load_cache() :: map()
  def load_cache do
    with {:ok, body} <- File.read(cache_path()),
         {:ok, %{"prices" => prices}} when is_map(prices) <- Jason.decode(body) do
      prices
    else
      _ -> %{}
    end
  end

  @doc "Metadata about the cache (when it was fetched, how many models), or `nil`."
  def cache_info do
    with {:ok, body} <- File.read(cache_path()),
         {:ok, %{"fetched_at" => at} = m} <- Jason.decode(body) do
      %{fetched_at: at, count: map_size(m["prices"] || %{})}
    else
      _ -> nil
    end
  end

  @doc """
  Fetch current prices from OpenRouter and the LiteLLM price map and write the
  cache. Returns `{:ok, count}` or `{:error, reason}`. Networked — call on demand
  (a button, `mix pepe usage prices --refresh`) or on a weekly tick, never per
  model call.
  """
  @spec refresh() :: {:ok, non_neg_integer()} | {:error, term()}
  def refresh do
    prices = Map.merge(fetch_litellm(), fetch_openrouter())

    if map_size(prices) == 0 do
      {:error, :no_prices_fetched}
    else
      File.mkdir_p!(Path.dirname(cache_path()))

      payload = %{"fetched_at" => System.system_time(:second), "prices" => prices}
      File.write!(cache_path(), Jason.encode!(payload))
      {:ok, map_size(prices)}
    end
  end

  @refresh_after 7 * 24 * 3600

  @doc "Is the cached price book missing or older than `max_age` seconds (default 7d)?"
  def stale?(max_age \\ @refresh_after) do
    case cache_info() do
      %{fetched_at: at} -> System.system_time(:second) - at > max_age
      _ -> true
    end
  end

  @doc """
  Refresh the price cache only if it's stale (older than a week). Called from the
  in-app scheduler while a server surface is up, so prices stay current on their
  own without ever fetching per model call.
  """
  def maybe_auto_refresh do
    if stale?() do
      case refresh() do
        {:ok, n} -> Logger.info("[pricing] auto-refreshed #{n} model prices")
        {:error, reason} -> Logger.warning("[pricing] auto-refresh failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Cost of a call in the operator's currency, given input/output token counts and a
  model's per-1M prices. `0.0` when unpriced.
  """
  @spec cost(number(), number(), number() | nil, number() | nil) :: float()
  def cost(input_tokens, output_tokens, input_price, output_price),
    do: per_million(input_tokens, input_price) + per_million(output_tokens, output_price)

  defp per_million(tokens, price) when is_number(tokens) and is_number(price),
    do: tokens / 1_000_000 * price

  defp per_million(_, _), do: 0.0

  ## live sources — best-effort; a failed fetch just contributes nothing

  defp fetch_litellm do
    case get_json(@litellm_url) do
      %{} = body ->
        for {id, m} <- body,
            is_map(m),
            i = m["input_cost_per_token"],
            o = m["output_cost_per_token"],
            is_number(i) or is_number(o),
            into: %{} do
          {String.downcase(to_string(id)), %{"in" => per_1m(i), "out" => per_1m(o)}}
        end

      _ ->
        %{}
    end
  end

  defp fetch_openrouter do
    case get_json(@openrouter_url) do
      %{"data" => data} when is_list(data) ->
        for m <- data,
            id = m["id"],
            is_binary(id),
            p = m["pricing"] || %{},
            i = num(p["prompt"]),
            o = num(p["completion"]),
            i || o,
            into: %{} do
          {String.downcase(id), %{"in" => per_1m(i), "out" => per_1m(o)}}
        end

      _ ->
        %{}
    end
  end

  defp get_json(url) do
    case Req.get(url, receive_timeout: 20_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, map} -> map
          _ -> nil
        end

      other ->
        Logger.warning("[pricing] fetch #{url} failed: #{inspect(other)}")
        nil
    end
  end

  # provider prices are per-token; store per 1M
  defp per_1m(n) when is_number(n), do: n * 1_000_000
  defp per_1m(_), do: nil

  defp num(n) when is_number(n), do: n

  defp num(s) when is_binary(s),
    do:
      (case Float.parse(s) do
         {f, _} -> f
         :error -> nil
       end)

  defp num(_), do: nil
end
