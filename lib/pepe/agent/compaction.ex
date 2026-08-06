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

  This is also the builtin occupant of `Pepe.Slots`'s `"compaction"` slot - a plugin can
  take over how a long conversation gets condensed (a different summarization strategy, a
  non-LLM heuristic, one that calls out to an external service) the same way `memory`/
  `web_search`/`sandbox` are already swappable. `compact/4` is the slot contract
  (`Pepe.Agent.Runtime` calls it through `Pepe.Slots.Guard`, never `compact/3`/
  `micro_compact/4` directly); those two stay as this module's own public API for any
  other caller (the manual `/compact` command, tests) that wants the builtin behavior
  specifically, bypassing whichever plugin might currently occupy the slot.
  """
  require Logger

  alias Pepe.Agent.MicroCompaction
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM
  alias Pepe.LLM.Message

  @default_window 128_000
  # Compact once the estimate passes this fraction of the window...
  @compact_at 0.75
  # ...keeping roughly this fraction of the window as recent, verbatim tail.
  @keep_tail 0.30
  # Don't bother summarizing fewer than this many middle messages.
  @min_middle 4

  @doc false
  def name, do: "builtin"

  @doc false
  def slot, do: "compaction"

  @doc """
  The `Pepe.Slots` "compaction" slot contract: condense `messages` for `model` (the
  agent's own `micro_compaction` flag picks the strategy, same as `Pepe.Agent.Runtime`
  used to decide inline before this became a slot), returning `{:ok, [message]}` always -
  never an `{:error, _}`, since both underlying paths (`compact/3`, `micro_compact/4`)
  already degrade to the original messages internally rather than fail. A non-default
  occupant that crashes or times out still degrades via `Pepe.Slots.Guard`'s own
  `:fallback` handling; this function only has to promise it never breaks the turn itself.
  """
  @spec compact(list(), Model.t(), Agent.t() | nil, String.t() | nil) :: {:ok, list()}
  def compact(messages, model, %{micro_compaction: true} = agent, session_key),
    do: {:ok, micro_compact(messages, model, agent.name, session_key)}

  def compact(messages, model, agent, _session_key),
    do: {:ok, compact(messages, model, agent_name(agent))}

  defp agent_name(%{name: name}), do: name
  defp agent_name(_), do: nil

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
  (possibly) shorter list. Used automatically inside the conversation loop. `agent_name`
  meters the summarizing call to the right agent - a compaction that goes unnoticed
  because nobody thought to bill for it is exactly the gap this parameter closes.
  """
  def compact(messages, model, agent_name \\ nil) do
    if needs?(messages, model) do
      case compact_now(messages, model, agent_name) do
        {:ok, compacted, _summary} -> compacted
        _ -> messages
      end
    else
      messages
    end
  end

  @doc """
  Opt-in per-turn amortized compaction (`agent.micro_compaction: true`). Instead of
  resummarizing the whole middle from scratch every turn once the window's crossed - what
  `compact/3` does, and why it re-pays for the whole, ever-growing middle every time it
  retriggers - this folds exactly the OLDEST not-yet-covered exchange into a running summary
  each call, so the input to that fold is always small (the running summary plus one
  exchange), never the whole middle. Stays on `model`, same as `compact_now/3` - see
  `Pepe.Agent.Utility`'s moduledoc for why a cheap utility model is deliberately not used for
  anything the agent has to go on reasoning from, and compaction is exactly that.

  Trades away prompt-cache prefix stability (the summary text changes turn over turn once
  this kicks in, unlike `compact/3`'s no-op-until-large default) for a bounded, smooth
  per-turn cost instead of one big mid-session stall - a real tradeoff, which is why this is
  opt-in rather than the default.

  `session_key` is the cross-turn identity the running summary is cached under
  (`Pepe.Agent.MicroCompaction`); with no session (a stateless oneshot has nothing to amortize
  across turns of) this falls back to ordinary `compact/3` behavior.
  """
  def micro_compact(messages, model, agent_name \\ nil, session_key)

  def micro_compact(messages, model, agent_name, nil), do: compact(messages, model, agent_name)

  def micro_compact(messages, model, agent_name, session_key) do
    if needs?(messages, model) do
      do_micro_compact(messages, model, agent_name, session_key)
    else
      messages
    end
  end

  @doc """
  Condense `messages` **now**, regardless of size (the manual `/compact`). Returns
  `{:ok, new_messages, summary}`, `{:ok, messages, "nothing to compact yet"}` when
  there's too little to summarize, or `{:error, reason}` (including `:no_model`).
  """
  def compact_now(messages, model, agent_name \\ nil)
  def compact_now(_messages, nil, _agent_name), do: {:error, :no_model}

  def compact_now(messages, model, agent_name) do
    {head, middle, tail} = split(messages, round(window(model) * @keep_tail))

    if length(middle) < @min_middle do
      {:ok, messages, "nothing to compact yet"}
    else
      case summarize(middle, model, agent_name) do
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

  defp do_micro_compact(messages, model, agent_name, session_key) do
    {head, middle, tail} = split(messages, round(window(model) * @keep_tail))
    all_exchanges = exchanges(middle)
    eligible = length(all_exchanges)

    {prior_summary, covered} = MicroCompaction.get(session_key) || {nil, 0}
    covered = min(covered, eligible)

    {summary, covered} =
      if covered < eligible do
        fold_one(prior_summary, Enum.at(all_exchanges, covered), model, agent_name, session_key, covered)
      else
        {prior_summary, covered}
      end

    unfolded = all_exchanges |> Enum.drop(covered) |> List.flatten()

    if summary do
      head ++ [summary_message(summary)] ++ unfolded ++ tail
    else
      messages
    end
  end

  # Groups a message list into "exchanges" - each starting on a `user`-role message (the
  # natural unit a fold covers), so a fold never splits an assistant tool-call from its
  # results any more than `split/2`'s tail boundary already avoids doing. Any messages before
  # the first user turn (possible if `middle` itself starts mid-exchange) form their own
  # leading group.
  defp exchanges(messages) do
    Enum.chunk_while(
      messages,
      [],
      fn
        %{"role" => "user"} = m, [] -> {:cont, [m]}
        %{"role" => "user"} = m, acc -> {:cont, Enum.reverse(acc), [m]}
        m, acc -> {:cont, [m | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
  end

  defp fold_one(prior_summary, exchange, model, agent_name, session_key, covered) do
    prompt = fold_prompt(prior_summary, render(exchange))

    case LLM.chat(
           model,
           [Message.system("You keep a running summary of a conversation, faithfully and compactly."), Message.user(prompt)],
           max_tokens: 400
         ) do
      {:ok, %{content: c} = result} when is_binary(c) and c != "" ->
        meter(agent_name, model, result[:usage])
        MicroCompaction.put(session_key, c, covered + 1)
        {c, covered + 1}

      _ ->
        {prior_summary, covered}
    end
  end

  defp fold_prompt(nil, exchange_text) do
    "Summarize the following conversation excerpt concisely, as the start of a running " <>
      "summary you'll keep extending. Preserve decisions, facts, current task state, and " <>
      "any identifiers, paths or values verbatim. Output only the summary.\n\n" <> exchange_text
  end

  defp fold_prompt(prior_summary, exchange_text) do
    "Here is the running summary of a conversation so far:\n\n#{prior_summary}\n\n" <>
      "Fold the following next exchange into it, updating it to stay concise while " <>
      "preserving decisions, facts, current task state, and identifiers/paths/values " <>
      "verbatim. Output only the updated summary.\n\n" <> exchange_text
  end

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

  defp summarize(middle, model, agent_name) do
    prompt =
      "Summarize the following conversation excerpt concisely. Preserve decisions made, " <>
        "facts established, current task state, and any identifiers, paths or values verbatim. " <>
        "Output only the summary.\n\n" <> render(middle)

    case LLM.chat(
           model,
           [Message.system("You summarize conversations faithfully and compactly."), Message.user(prompt)],
           max_tokens: 800
         ) do
      {:ok, %{content: c} = result} when is_binary(c) and c != "" ->
        meter(agent_name, model, result[:usage])
        {:ok, c}

      {:ok, _} ->
        {:error, :empty_summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp meter(agent_name, model, usage) when is_binary(agent_name) and is_map(usage),
    do: Pepe.Usage.record(agent_name, model, usage)

  defp meter(_agent_name, _model, _usage), do: :ok

  # A `<system-reminder>` user turn, NOT a second `system` message. The Anthropic and Responses
  # adapters keep only the FIRST system message and drop the rest - a mid-list `system` summary
  # would be silently deleted on exactly the two production adapters, so the condensed middle would
  # vanish instead of being summarized. Framed as a user turn, every adapter keeps it. Same trick as
  # Pepe.Agent.Session.goal_reminder/1.
  defp summary_message(summary) do
    Message.user(
      "<system-reminder>\nSummary of the earlier conversation (older turns were condensed to fit the context window):\n" <>
        summary <> "\n</system-reminder>"
    )
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
