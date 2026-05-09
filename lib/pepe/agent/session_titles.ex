defmodule Pepe.Agent.SessionTitles do
  @moduledoc """
  Human labels for sessions, shown in the dashboard sidebar. Set by hand with `/name`, or
  written for you after the first exchange (`generate/3`). A small `key => title` map
  persisted next to the session files, kept out of the per-turn session JSON so the hot save
  path never touches it. Disposable: losing it only reverts a session to showing its key.
  """
  alias Pepe.Agent.Utility
  alias Pepe.Config
  alias Pepe.LLM
  alias Pepe.LLM.Message

  @instruction """
  Name this conversation. Reply with a title of at most five words, in the language of the \
  message, with no quotes, no punctuation at the end, and nothing else. Describe what the \
  conversation is about, not who is asking.
  """

  # The whole conversation is not needed to name it, and sending it would cost more than the
  # naming is worth. The opening message is what a conversation is about.
  @excerpt 600

  # Room for a small model that reasons: give it a tight budget and it spends the lot on
  # thinking, returns an empty string, and we pay for silence. See Pepe.Agent.Utility.
  @max_tokens 256

  # A title is furniture. If the model returns something long, it ran off writing prose
  # instead of a label, and prose is not a title.
  @max_title 60

  # How many words of the opening message make a label when no model writes one.
  @trim_words 7

  @doc "The title for `key`, or `nil` when it has none."
  def get(key), do: Map.get(all(), to_string(key))

  @doc """
  Name a session from its opening message and store it.

  With a `utility_model` on the agent, a cheap model writes the name. With none, the opening
  message is trimmed down to a label instead. The second is not a degraded mode so much as a
  sober one: what the sidebar needs is for you to recognise the conversation, and the first
  few words of what you asked do that at no cost, offline, and without handing anybody's
  opening message to a model to read.

  Best-effort throughout. A session that already has a title is left alone, because a name a
  human chose is not ours to overwrite, and a model that is unreachable, slow, or that
  answers with a paragraph falls back to the trim rather than to nothing.

  Returns `{:ok, title}` or `:skip` (only when there was nothing to name).
  """
  @spec generate(String.t(), Pepe.Config.Agent.t(), String.t()) :: {:ok, String.t()} | :skip
  def generate(key, agent, first_message) do
    with nil <- get(key),
         opening when opening != "" <- excerpt(first_message) do
      title = written(agent, opening) || trimmed(opening)
      store(key, title)
    else
      _ -> :skip
    end
  end

  defp store(_key, ""), do: :skip

  defp store(key, title) do
    set(key, title)
    {:ok, title}
  end

  # The cheap model writes it, when the agent has one. nil on any disappointment (no utility
  # model configured, unreachable, empty answer, prose instead of a label) so the caller
  # falls through to the trim.
  defp written(agent, opening) do
    with model when not is_nil(model) <- Utility.model(agent),
         {:ok, %{content: content} = result} when is_binary(content) <-
           LLM.chat(
             model,
             [Message.system(@instruction), Message.user(opening)],
             max_tokens: @max_tokens,
             receive_timeout: 20_000
           ),
         title when title != "" <- clean(content) do
      # These tokens are spent on the company's behalf like any other. Metering them here
      # keeps the ledger honest: the alternative is spending that no invoice ever sees.
      meter(agent, model, result[:usage])
      title
    else
      _ -> nil
    end
  end

  # No model, no network, no cost: the opening message cut down to something you can scan in
  # a sidebar. Cut on a word boundary, because a title ending mid-word reads like a bug.
  defp trimmed(opening) do
    words =
      opening
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    words
    |> Enum.reduce_while([], fn word, taken ->
      candidate = taken ++ [word]

      if length(candidate) > @trim_words or String.length(Enum.join(candidate, " ")) > @max_title,
        do: {:halt, taken},
        else: {:cont, candidate}
    end)
    |> finish_trim(words)
  end

  # An opening long enough to have been cut says so, so nobody reads the label as the whole
  # of what they asked.
  defp finish_trim([], _words), do: ""

  defp finish_trim(taken, words) do
    title = taken |> Enum.join(" ") |> String.trim_trailing(",") |> String.trim_trailing(":")
    if length(taken) < length(words), do: title <> "...", else: title
  end

  defp meter(%{name: agent}, model, usage) when is_map(usage),
    do: Pepe.Usage.record(agent, model, usage)

  defp meter(_agent, _model, _usage), do: :ok

  defp excerpt(text) do
    text = String.trim(to_string(text))
    if String.length(text) > @excerpt, do: String.slice(text, 0, @excerpt), else: text
  end

  # Models like to answer a request for a title with a title in quotes, or with a helpful
  # sentence around it. Take the first line, drop the decoration, and refuse anything still
  # too long to be a label.
  defp clean(content) do
    title =
      content
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.trim()
      |> String.trim(~s("))
      |> String.trim("'")
      |> String.trim()

    if String.length(title) <= @max_title, do: title, else: ""
  end

  @doc "All labels as a `key => title` map."
  def all do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Set the label for `key`; an empty/blank title clears it. Returns `:ok`."
  def set(key, title) do
    key = to_string(key)
    title = String.trim(to_string(title))
    map = all()

    map = if title == "", do: Map.delete(map, key), else: Map.put(map, key, title)
    write(map)
  end

  @doc "Forget the label for `key` (e.g. when its session is deleted)."
  def delete(key), do: all() |> Map.delete(to_string(key)) |> write()

  defp write(map) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
    :ok
  end

  defp path, do: Path.join([Config.home(), "data", "session_titles.json"])
end
