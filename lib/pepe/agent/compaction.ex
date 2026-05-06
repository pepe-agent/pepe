defmodule Pepe.Agent.Compaction do
  @moduledoc """
  Keeps a long conversation under the model's context window so an agent can run
  indefinitely without a manual reset.

  When the estimated token count crosses a fraction of the window, the **middle** of
  the history is replaced by a short summary the model itself produces, while the
  system prompt(s) at the **head** and the most recent turns at the **tail** are kept
  verbatim. The tail boundary never splits an assistant tool-call from its results, so
  the trimmed history stays valid. The full transcript still lives in `Pepe.Trace`;
  only the in-context message list is condensed.

  Failure-safe: if the summarizing call fails, the original (uncondensed) messages are
  returned so a request never breaks just because compaction couldn't run.
  """
  require Logger

  alias Pepe.LLM
  alias Pepe.LLM.Message

  @default_window 128_000
  # Compact once the estimate passes this fraction of the window...
  @compact_at 0.75
  # ...keeping roughly this fraction of the window as recent, verbatim tail.
  @keep_tail 0.30
  # Don't bother summarizing fewer than this many middle messages.
  @min_middle 4

  @doc "Rough token estimate for a message list (~4 chars/token + a little overhead)."
  def estimate_tokens(messages) do
    Enum.reduce(messages, 0, fn m, acc -> acc + div(byte_size(text_of(m)), 4) + 8 end)
  end

  @doc "The model's declared context window, or a conservative default."
  def window(model), do: (is_integer(model.context_window) && model.context_window) || @default_window

  @doc "Is the history large enough (vs the window) to compact?"
  def needs?(messages, model), do: estimate_tokens(messages) > round(window(model) * @compact_at)

  @doc """
  Split into `{head, middle, tail}`: `head` is the leading system message(s); `tail` is
  the most recent messages within `keep_tokens` (never starting on an orphan tool
  result); `middle` is everything in between (the part that gets summarized).
  """
  def split(messages, keep_tokens) do
    {head, rest} = Enum.split_while(messages, &(&1["role"] == "system"))
    tail = take_tail(rest, keep_tokens)
    middle = Enum.take(rest, length(rest) - length(tail))
    {head, middle, tail}
  end

  @doc """
  Condense `messages` for `model` **when needed** (near the window), returning the
  (possibly) shorter list. Used automatically inside the conversation loop.
  """
  def compact(messages, model) do
    if needs?(messages, model) do
      case compact_now(messages, model) do
        {:ok, compacted, _summary} -> compacted
        _ -> messages
      end
    else
      messages
    end
  end

  @doc """
  Condense `messages` **now**, regardless of size (the manual `/compact`). Returns
  `{:ok, new_messages, summary}`, `{:ok, messages, "nothing to compact yet"}` when
  there's too little to summarize, or `{:error, reason}` (including `:no_model`).
  """
  def compact_now(_messages, nil), do: {:error, :no_model}

  def compact_now(messages, model) do
    {head, middle, tail} = split(messages, round(window(model) * @keep_tail))

    if length(middle) < @min_middle do
      {:ok, messages, "nothing to compact yet"}
    else
      case summarize(middle, model) do
        {:ok, summary} ->
          compacted = head ++ [summary_message(summary)] ++ tail
          Logger.info("[compaction] condensed history ~#{estimate_tokens(messages)} -> ~#{estimate_tokens(compacted)} tokens")
          {:ok, compacted, summary}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- internals ------------------------------------------------------------------

  defp take_tail(rest, keep_tokens) do
    {tail, _tokens} =
      rest
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn m, {acc, tok} ->
        if tok >= keep_tokens, do: {acc, tok}, else: {[m | acc], tok + div(byte_size(text_of(m)), 4) + 8}
      end)

    drop_leading_tool_results(tail)
  end

  # A tail must not begin with a `tool` result - it needs the assistant tool-call turn
  # that precedes it, which lives in the (soon-to-be-summarized) middle.
  defp drop_leading_tool_results([%{"role" => "tool"} | rest]), do: drop_leading_tool_results(rest)
  defp drop_leading_tool_results(tail), do: tail

  defp summarize(middle, model) do
    prompt =
      "Summarize the following conversation excerpt concisely. Preserve decisions made, " <>
        "facts established, current task state, and any identifiers, paths or values verbatim. " <>
        "Output only the summary.\n\n" <> render(middle)

    case LLM.chat(
           model,
           [Message.system("You summarize conversations faithfully and compactly."), Message.user(prompt)],
           max_tokens: 800
         ) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> {:ok, c}
      {:ok, _} -> {:error, :empty_summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp summary_message(summary) do
    Message.system("Summary of the earlier conversation (older turns were condensed to fit the context window):\n" <> summary)
  end

  defp render(messages) do
    Enum.map_join(messages, "\n", fn m -> "#{m["role"]}: #{text_of(m)}" end)
  end

  # (compaction runs inline in the loop; nothing to notify)

  defp text_of(m) do
    calls =
      case m["tool_calls"] do
        list when is_list(list) ->
          Enum.map_join(list, " ", fn c -> to_string(get_in(c, ["function", "arguments"]) || "") end)

        _ ->
          ""
      end

    String.trim(to_string(m["content"] || "") <> " " <> calls)
  end
end
