defmodule Pepe.Watch.Delivery do
  @moduledoc """
  Route a fired watch's message back to the channel it was created from.

  The `origin` is captured when the watch is created, so delivery lands where you
  asked from - even after a restart. Returns `:ok` when it reached the user, or
  `{:error, reason}` so the scheduler can hold the message (`pending_delivery`) and
  retry later - that's how a watch "delivers when you're reachable again".

  Connected surfaces (TUI, WebSocket) are reached over `Phoenix.PubSub`: a live
  session subscribes to its origin topic (and registers in `Pepe.Watch.Subscribers`
  so we can tell it's actually listening). If nobody's home the message is reported
  undelivered and held for a later flush.
  """

  require Logger

  @pubsub Pepe.PubSub

  @doc "The PubSub topic / subscriber key a connected surface uses for an origin."
  def topic(%{"channel" => channel, "key" => key}), do: "watch:#{channel}:#{key}"
  def topic(%{"channel" => channel}), do: "watch:#{channel}"

  @spec deliver(map(), String.t()) :: :ok | {:error, term()}
  def deliver(%{"channel" => "log"} = origin, text) do
    Logger.info("[watch] #{origin["key"] || ""} #{text}")
    :ok
  end

  def deliver(%{"channel" => "telegram"} = origin, text) do
    Pepe.Gateways.Telegram.deliver_watch(origin, text)
  end

  def deliver(%{"channel" => channel} = origin, text) when channel in ["tui", "ws"] do
    if reachable?(origin) do
      Phoenix.PubSub.broadcast(@pubsub, topic(origin), {:watch_message, origin, text})
      :ok
    else
      {:error, :offline}
    end
  end

  def deliver(_origin, _text), do: {:error, :no_origin}

  # Is a live surface currently subscribed to this origin's topic?
  defp reachable?(origin) do
    Registry.lookup(Pepe.Watch.Subscribers, topic(origin)) != []
  end

  @doc """
  Build an origin map from a tool `ctx` - the channel plus a stable key so delivery
  can find the same conversation later. Falls back to `log` when the surface is
  unknown or can't receive proactive messages (the stateless HTTP API).
  """
  def origin_from_ctx(ctx) do
    case ctx[:session_key] do
      "telegram:" <> _ = key -> telegram_origin(key)
      "tui:" <> _ = key -> %{"channel" => "tui", "key" => key}
      "ws:" <> _ = key -> %{"channel" => "ws", "key" => key}
      key when is_binary(key) -> %{"channel" => "log", "key" => key}
      _ -> %{"channel" => "log"}
    end
  end

  # "telegram:<chat>" (default bot) or "telegram:<bot>:<chat>" (named bot).
  defp telegram_origin(key) do
    case String.split(key, ":") do
      ["telegram", chat] ->
        %{"channel" => "telegram", "bot" => "default", "chat_id" => chat, "key" => key}

      ["telegram", bot, chat] ->
        %{"channel" => "telegram", "bot" => bot, "chat_id" => chat, "key" => key}

      _ ->
        %{"channel" => "log", "key" => key}
    end
  end
end
