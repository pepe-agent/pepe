defmodule Pepe.Agent.RecipeNote do
  @moduledoc """
  Make sure what worked after trial and error gets written down - before the answer, in the
  same turn.

  `TOOLS.md` (see `Pepe.Agent.Workspace`) is what lets a fresh conversation start knowing the
  recipe, but the system prompt only asks the agent to write it; whether a model does is up to
  the model, and measured against a real one it often finished the job and simply did not
  (the next conversation then started from nothing and asked the user where to look). A
  background review is the usual answer and it costs a second model call on every turn it
  runs. This is the cheaper one: the loop already knows exactly when a turn earned a note, so
  it appends one short reminder to *that model call only* - never persisted, never part of the
  system prompt, which stays byte-identical across a session and cacheable.

  ## When it fires

  The turn in progress had a tool call fail and a later one succeed (the shape of "found out
  how by trying"), or took at least two successful tool calls (the shape of "looked up how,
  then did it": a smaller model finds the way with `--help` and no error at all, and a bar of
  "only after a failure" left exactly that unwritten), and nothing this turn has touched
  `TOOLS.md` yet, and the agent has a way to write it. A clean one-call turn, or a
  turn that already wrote the note, gets nothing, and the note itself tells the model to skip
  a one-off.

  It never fires inside a background review run, which has its own instructions and would
  otherwise be told to write notes about writing notes; nor in a conversation that may not feed
  what the agent keeps (`learn: false`: an anonymous widget visitor, a client on a customer-facing
  bot); nor in a turn that took in outside content (a fetched page, a search result), because
  `TOOLS.md` is read at the start of every later conversation and what a stranger's text says
  must not be able to get in there.
  """

  alias Pepe.Agent.SkillLearning
  alias Pepe.LLM.Message
  alias Pepe.Tools

  @writers ~w(write_file edit_file bash)

  @doc "The ephemeral notes to append to this model call only: `[]` unless the turn earned one."
  @spec reminders(map(), [map()], map()) :: [map()]
  def reminders(agent, messages, ctx) when is_map(agent) and is_list(messages) do
    turn = SkillLearning.current_turn(messages)

    cond do
      blocked?(agent, ctx, turn) -> []
      earned?(turn) and not written?(turn) -> [Message.user(note())]
      stuck?(turn) -> [Message.user(stuck_note())]
      true -> []
    end
  end

  def reminders(_agent, _messages, _ctx), do: []

  # No note for a background review run, for a conversation that may not feed what the agent
  # keeps, for an agent with nowhere to write, or for a turn that took in outside content.
  defp blocked?(agent, ctx, turn) do
    is_binary(ctx[:review_run]) or ctx[:learn] == false or not can_write?(agent) or SkillLearning.tainted?(turn)
  end

  defp can_write?(agent) do
    case Map.get(agent, :tools) do
      tools when is_list(tools) -> Enum.any?(@writers, &(&1 in tools))
      _ -> true
    end
  end

  @min_successful_calls 2

  @doc "Did this turn have a failure followed by a success, or at least two successful tool calls?"
  @spec earned?([map()]) :: boolean()
  def earned?(turn), do: struggled?(turn) or successful_calls(turn) >= @min_successful_calls

  defp successful_calls(turn),
    do: Enum.count(turn, &(&1["role"] == "tool" and is_binary(&1["content"]) and not Tools.error?(&1["content"])))

  defp struggled?(turn) do
    results = for msg <- turn, msg["role"] == "tool", is_binary(msg["content"]), do: Tools.error?(msg["content"])

    case Enum.drop_while(results, &(&1 == false)) do
      [true | rest] -> Enum.any?(rest, &(&1 == false))
      _ -> false
    end
  end

  # The last tool result of the turn is a failure the agent has not got past (and not a refusal
  # by a person or a permission gate: retrying one of those is exactly wrong). Measured against a
  # real model, an agent whose remembered recipe had gone stale made one failing call and told
  # the user it could not do it, without reading the tool's own `--help` or trying the next
  # variation.
  defp stuck?(turn) do
    case turn |> Enum.filter(&(&1["role"] == "tool" and is_binary(&1["content"]))) |> List.last() do
      %{"content" => content} -> Tools.error?(content) and not refusal?(content)
      nil -> false
    end
  end

  defp refusal?(content),
    do: content =~ ~r/did not authorize|did not run|permission prompt|needs a human|nobody (was asked|answered)/i

  @doc "Did a call this turn name `TOOLS.md` (a write_file/edit_file path, or a shell command appending to it)?"
  @spec written?([map()]) :: boolean()
  # Cruder than parsing, and right in the direction that matters - a turn that touched it is not
  # nagged again.
  def written?(turn) do
    Enum.any?(turn, fn msg ->
      msg["role"] == "assistant" and is_list(msg["tool_calls"]) and
        Enum.any?(msg["tool_calls"], &String.contains?(to_string(get_in(&1, ["function", "arguments"])), "TOOLS.md"))
    end)
  end

  defp note do
    """
    <system-reminder>
    This turn took trial and error, or several steps, to get working. Before you answer, record
    the recipe in `TOOLS.md`: read it first, then add or edit one entry for this kind of task -
    what it is called, the exact command, tool and arguments that worked, and the traps that
    failed first, so the next conversation does it in one go. Never a secret's value, only where
    it is kept. Skip this only if it was truly a one-off nobody will ask for again. Then answer
    normally and do not mention this note. Do it with a tool call now; do not offer to do it
    later or ask whether to.
    </system-reminder>
    """
  end

  defp stuck_note do
    """
    <system-reminder>
    That call failed. A failure is information, not the end: read the error and the tool's own
    usage or help, and try the next plausible variation (another option, another argument,
    another route) before you say anything to the user. If you were following a recipe from
    `TOOLS.md` or from memory, it may be out of date: find what changed, and correct the note
    once you have it working. Report being blocked only after you have genuinely tried, and say
    what you tried. Do not mention this note.
    </system-reminder>
    """
  end
end
