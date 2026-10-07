defmodule Pepe.Labels do
  @moduledoc """
  What to call a connection, a channel or a person on screen.

  Platform ids (`A0C5LM7LHS8`, `D0C5LMVCHEY`, `U07ABC`) are what the config and the sessions
  are keyed by, and they never change, but nobody reads them. So the operator may give each
  one a label: a connection's lives on its entry (`"label"` on the webhook or the Telegram
  bot), a channel's and a person's on their recorded rows (`Pepe.SeenChannels`,
  `Pepe.SeenPeople`), apart from the provider's own `name` so a refresh never overwrites it.

  Display text only: the label wins, the provider's name is the fallback, the id the last
  resort, and every screen that shows one of these goes through here so none is missed.
  Nothing is ever matched or authorized by a label; that stays by id.
  """

  alias Pepe.Config
  alias Pepe.SeenChannels
  alias Pepe.SeenPeople

  @max 60

  @typedoc "Something with an id and what to call it: `text` is what shows, `id` is the key."
  @type named :: %{id: String.t(), text: String.t(), label: String.t() | nil}

  @doc "A label as stored: trimmed, at most #{@max} characters, `nil` when blank."
  @spec clean(String.t() | nil) :: String.t() | nil
  def clean(label) when is_binary(label) do
    case label |> String.trim() |> String.slice(0, @max) do
      "" -> nil
      text -> text
    end
  end

  def clean(_label), do: nil

  @doc "A connection (webhook slug or Telegram bot name) with its label, when it has one."
  @spec connection(String.t()) :: named()
  def connection(key) when is_binary(key) do
    label = clean(connection_label(key))
    %{id: key, text: label || key, label: label}
  end

  defp connection_label(key) do
    case Config.get_webhook(key) do
      %{"label" => label} -> label
      _ -> (Config.telegram_bot(key) || %{})["label"]
    end
  end

  @doc "A connection entry (webhook or bot map) with its label, for a card that already holds the entry."
  @spec connection(String.t(), map() | nil) :: named()
  def connection(key, entry) when is_binary(key) do
    label = clean((entry || %{})["label"])
    %{id: key, text: label || key, label: label}
  end

  @doc "A channel of a connection: its label, else the provider's name, else the id."
  @spec channel(String.t(), String.t()) :: named()
  def channel(connection, channel) when is_binary(connection) and is_binary(channel) do
    case SeenChannels.get(connection, channel) do
      nil -> %{id: channel, text: channel, label: nil}
      row -> channel_row(row)
    end
  end

  @doc "The same, from a row already loaded."
  @spec channel_row(SeenChannels.Channel.t()) :: named()
  def channel_row(row), do: %{id: row.channel, text: row.label || row.name || row.channel, label: row.label}

  @doc "A person on a connection: their label, else the provider's name, else the id."
  @spec person(String.t(), String.t()) :: named()
  def person(connection, person) when is_binary(connection) and is_binary(person) do
    case SeenPeople.get(connection, person) do
      nil -> %{id: person, text: person, label: nil}
      row -> %{id: person, text: row.label || row.name || person, label: row.label}
    end
  end

  @doc """
  A session or delivery key as a person reads it: a Telegram key (`telegram:<chat>` or
  `telegram:<bot>:<chat>`, with an optional `#t<topic>`) becomes the bot and the chat by name;
  anything else is returned as it is.
  """
  @spec session(String.t()) :: String.t()
  def session("telegram:" <> rest = key) do
    {bot, chat} =
      case String.split(rest, ":", parts: 2) do
        [chat] -> {"default", chat}
        [bot, chat] -> {bot, chat}
      end

    chat_text = channel(bot, chat).text
    if chat_text == chat, do: key, else: "#{connection(bot).text}: #{chat_text}"
  end

  def session(key), do: key
end
