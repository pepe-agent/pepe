defmodule Pepe.Agent.SessionTitles do
  @moduledoc """
  Human labels for sessions, shown in the dashboard sidebar. Set by hand with `/name`, or
  written for you after the first exchange (`generate/3`). A small `key => title` map
  persisted next to the session files, kept out of the per-turn session JSON so the hot save
  path never touches it. Disposable: losing it only reverts a session to showing its key.
  """
  require Logger

  alias Pepe.Agent.Utility
  alias Pepe.Config
  alias Pepe.LLM
  alias Pepe.LLM.Message

  @instruction """
  Name this conversation. Reply with a title of at most five words, in the language of the \
  message, with no quotes, no punctuation at the end, and nothing else. Describe what the \
  conversation is about, not who is asking. If everything said so far is only a greeting or \
  small talk with no real topic yet ("hi", "how can I help you today?"), reply with exactly \
  one word and nothing else: PENDING
  """

  # The whole conversation is not needed to name it, and sending it would cost more than the
  # naming is worth. The opening message is what a conversation is about.
  @excerpt 600

  # Room for a small model that reasons: give it a tight budget and it spends the lot on
  # thinking, returns an empty string, and we pay for silence. See Pepe.Agent.Utility.
  @max_tokens 256

  # A title is furniture. If the model returns something long, it ran off writing prose
  # instead of a label, and prose is not a label.
  @max_title 60

  # How many words of the opening message make a label when no model writes one.
  @trim_words 7

  # Below this, a trimmed candidate is treated as too thin to be a real topic and this turn
  # defers instead of storing it. Word count alone can't reliably tell a genuine short topic
  # from filler ("oi", "how can I help?") - that judgment belongs to the model-based path's
  # own `PENDING` verdict - so this floor is deliberately low: just enough to skip the
  # emptiest, single/two-word cases on the no-model fallback without silently swallowing a
  # legitimately short but real topic.
  @min_trim_words 3

  @doc "The title for `key`, or `nil` when it has none."
  def get(key), do: Map.get(all(), to_string(key))

  @doc """
  Name a session from the current turn's user message and the reply it got, and store it.

  With a `utility_model` on the agent, a cheap model writes the name from both - not the
  message alone, which is why this waits for an answer before ever calling in (see
  `Pepe.Agent.Session.maybe_title/1`). A greeting ("oi", "hey", "bom dia") carries no topic
  on its own, and the model is told explicitly to say so (`PENDING`) rather than force a
  title out of small talk still in progress. A `PENDING` verdict skips naming this turn;
  `Pepe.Agent.Session` retries on each of the next few turns, passing whatever the person
  actually said most recently each time - not the same opening message forever - as the
  conversation develops, rather than only ever getting one attempt with one fixed input.

  With no utility model there is no semantic judgment available at all, so this stays
  simple and predictable on purpose rather than guessing: the message is trimmed down to a
  label (never the reply - a heuristic can't reliably tell a genuinely short topic from an
  assistant's own filler reply, so it doesn't try). `force?` (true once the retry budget is
  spent) accepts whatever there is even if it still reads thin, so a session is never left
  unnamed forever over conversation that stays small talk.

  Best-effort throughout. A session that already has a title is left alone, because a name a
  human chose (`/name`, or the sidebar's own rename) is not ours to overwrite, and a model
  that is unreachable, slow, or that answers with a paragraph falls back to the trim rather
  than to nothing.

  Returns `{:ok, title}` or `:skip` (nothing to name yet, or genuinely nothing to name).
  """
  @spec generate(String.t(), Pepe.Config.Agent.t(), String.t(), String.t(), boolean()) :: {:ok, String.t()} | :skip
  def generate(key, agent, message, reply \\ "", force? \\ false) do
    with nil <- get(key),
         text when text != "" <- excerpt(message) do
      case named(agent, text, excerpt(reply), force?) do
        {:ok, title} -> store(key, title)
        :pending -> :skip
      end
    else
      _ -> :skip
    end
  end

  defp named(agent, text, reply, force?) do
    case written(agent, text, reply) do
      {:title, title} -> {:ok, title}
      :pending -> if force?, do: {:ok, trimmed(text)}, else: :pending
      :unavailable -> trim_or_defer(text, force?)
    end
  end

  defp trim_or_defer(text, force?) do
    title = trimmed(text)
    words = title |> String.trim_trailing("...") |> String.split(~r/\s+/, trim: true) |> length()

    if force? or words >= @min_trim_words or title == "", do: {:ok, title}, else: :pending
  end

  defp store(_key, ""), do: :skip

  # Re-checks get(key) right before writing, not just at the top of generate/5: the naming
  # Task this runs inside can take up to ~20s (LLM.chat's own receive_timeout), long enough
  # for a human to rename the session (the header's own rename field, or /name) while it's
  # still in flight. Without this, whichever finishes last wins regardless of which one a
  # human actually meant to stick - the one thing this whole feature promises never happens.
  defp store(key, title) do
    if is_nil(get(key)) do
      set(key, title)
      {:ok, title}
    else
      :skip
    end
  end

  # The cheap model writes it, when the agent has one - given both turns, so it can name
  # what the conversation actually turned out to be about instead of guessing from one line,
  # and it can say `PENDING` itself instead of forcing a title out of small talk. `:unavailable`
  # covers every kind of disappointment that means "couldn't ask" (no utility model
  # configured, unreachable, empty answer, prose instead of a label) so the caller falls
  # through to the trim; `:pending` is the model's own explicit "not yet".
  defp written(agent, opening, reply) do
    context = if reply == "", do: opening, else: "User: #{opening}\nAssistant: #{reply}"

    with model when not is_nil(model) <- Utility.model(agent),
         {:ok, %{content: content} = result} when is_binary(content) <-
           LLM.chat(
             model,
             [Message.system(@instruction), Message.user(context)],
             max_tokens: @max_tokens,
             receive_timeout: 20_000
           ) do
      # These tokens are spent on the project's behalf like any other. Metering them here
      # keeps the ledger honest: the alternative is spending that no invoice ever sees.
      meter(agent, model, result[:usage])
      classify(content)
    else
      _ -> :unavailable
    end
  end

  defp classify(content) do
    case clean(content) do
      "" -> :unavailable
      cleaned -> if pending?(cleaned), do: :pending, else: {:title, cleaned}
    end
  end

  defp pending?(text), do: text |> String.trim_trailing(".") |> String.upcase() == "PENDING"

  # No model, no network, no cost: the message cut down to something you can scan in a
  # sidebar. Cut on a word boundary, because a title ending mid-word reads like a bug. Never
  # the reply - an earlier version picked whichever of the two had more words, reasoning a
  # bare "oi" is short by construction and a topic-bearing reply usually isn't, but an
  # assistant's own filler reply ("how can I help you today?") is often just as long as a
  # real topic and that heuristic can't tell them apart. trim_or_defer/2's word-count floor
  # is the only judgment call left on this path, and it's simpler (and more predictable) to
  # apply it to the thing the person actually said.
  defp trimmed(text) do
    words = first_line_words(text)

    words
    |> Enum.reduce_while([], fn word, taken ->
      candidate = taken ++ [word]

      if length(candidate) > @trim_words or String.length(Enum.join(candidate, " ")) > @max_title,
        do: {:halt, taken},
        else: {:cont, candidate}
    end)
    |> finish_trim(words)
  end

  defp first_line_words(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
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

  # Disposable, per the moduledoc: losing a write here only reverts a session to
  # showing its key, so a failure (most often this runs in the background, after its
  # own session/test has already torn down the directory it would write into) is
  # logged, never raised.
  defp write(map) do
    path = path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(map)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[session titles] could not write #{path}: #{:file.format_error(reason)}")
        :ok
    end
  end

  defp path, do: Path.join([Config.home(), "data", "session_titles.json"])
end
