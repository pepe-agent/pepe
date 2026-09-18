defmodule Pepe.Agent.SkillLearning do
  @moduledoc """
  Turn the work an agent just did into a skill it keeps - without the user having
  to think of asking for one.

  An agent already writes a skill when it is told to ("remember how to do this as a
  skill"), which means the only procedures ever written down are the ones the *user*
  remembered to ask about, right after a task they were busy with. Almost nothing is
  written down that way. This module closes the gap from the other side: it watches
  what a turn actually did and, when the turn earned it, hands the model one
  ephemeral note inviting it to *offer* - never to write anything unasked.

  Two different moments, one flag (`skill_learning` on `Pepe.Config.Agent`):

    * **A procedure worth keeping.** The turn took real work - at least four
      successful tool calls across at least two distinct tools - and no existing
      skill was consulted. That is the shape of know-how that was derived on the
      spot, so it is worth asking whether it should be derived again next time or
      simply read.
    * **A skill that turned out to be wrong.** An existing skill *was* read this
      turn and something after it failed. The skill said one thing, reality said
      another, and the agent now knows something its own instructions don't. That is
      an edit to that skill, never a new one - see the `skill-creator` skill's
      "Edit / audit / tidy" section, which the note points at explicitly.

  One flag covers both because they are one decision, not two: may this agent bring
  up changes to its own skill library unprompted? An operator who wants a skill
  corrected when it is found wrong but not written when it is found missing (or the
  reverse) would be choosing between two halves of the same habit, and each half on
  its own leaves the library in a worse state than either extreme - all new skills
  and none of them maintained, or a set of skills that never grows.

  ## Why a runtime signal instead of another line in the system prompt

  `capability_nudge` (see `Pepe.Agent.Workspace.capability_nudge_note/1`) is pure
  prose: a paragraph in every system prompt telling the agent to use its judgement
  about when a capability is worth a mention. It has no runtime component at all,
  and for what it does that is the right shape - "was this exchange transactional?"
  is not something code can measure.

  "Was this task complex enough to be worth remembering?" *is*. A second judgement
  paragraph here would have paid tokens on every single prompt, including the
  millions of turns where nothing happened worth saving, to ask the model to
  re-derive something the loop already knows exactly. So the criterion lives here,
  in code, and an agent with the flag on pays nothing at all until a turn actually
  crosses the bar - at which point it gets one short note appended to *that model
  call only*, never persisted and never part of the system prompt (which stays
  byte-identical across a session, and therefore still cacheable by the provider).

  ## The thresholds are a judgement call

  Four calls across two tools is a deliberate guess at "more than a lookup, less
  than every multi-step errand". It is the one number here worth revisiting against
  real traces: too low and an agent offers to save a two-step chore, too high and
  genuinely reusable procedures slip past. The distinct-tool floor is what keeps a
  retry loop (the same `bash` five times) from reading as a procedure.

  Crossing the bar only produces an *invitation*. The note tells the model to stay
  quiet unless the procedure is genuinely reusable, to offer once, and to write
  nothing without an explicit yes - so the threshold decides when the question may
  be asked, never what the answer is.
  """

  alias Pepe.LLM.Message
  alias Pepe.Tools

  # See "The thresholds are a judgement call" above before changing either.
  @min_tool_calls 4
  @min_distinct_tools 2

  # Writing or editing a skill is a file write. An agent without `write_file` cannot act on
  # the offer, so it never gets made - an offer it can only walk back is worse than silence.
  @required_tool "write_file"

  @doc """
  The ephemeral notes to append to *this model call only*, given the loop's history
  so far.

  Only the current turn (everything after the last user message) is ever examined.
  Returns `[]` - the overwhelmingly common case - unless the agent opted in and the
  turn crossed one of the two bars.
  """
  @spec reminders(map(), [map()]) :: [map()]
  def reminders(agent, messages) when is_map(agent) and is_list(messages) do
    if enabled?(agent), do: notes_for(current_turn(messages)), else: []
  end

  def reminders(_agent, _messages), do: []

  defp notes_for(turn) do
    case refine_target(turn) do
      {:ok, skill} -> [Message.user(refine_note(skill))]
      :none -> if worth_saving?(turn), do: [Message.user(save_note())], else: []
    end
  end

  defp enabled?(agent) do
    tools = Map.get(agent, :tools)
    Map.get(agent, :skill_learning) == true and is_list(tools) and @required_tool in tools
  end

  @doc """
  The messages belonging to the turn in progress: everything after the last user
  message.

  The loop is handed the whole conversation, and an earlier turn's tool calls are
  not this turn's work - counting them would make every message after a busy turn
  look busy too. A mid-turn steer (`Pepe.Agent.Session.inline/2`) is a user message
  and so restarts the window, which errs in the conservative direction: at worst the
  agent stays quiet about a procedure it did work out.
  """
  @spec current_turn([map()]) :: [map()]
  def current_turn(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1["role"] != "user"))
    |> Enum.reverse()
  end

  @doc """
  Whether this turn's work looks like a procedure worth writing down: enough
  successful tool calls, across enough different tools, with no existing skill
  consulted.

  A turn that read a skill is deliberately excluded even when it is otherwise busy.
  The procedure is already written down; what such a turn can produce is an *edit*
  to it (see `refine_target/1`), not a second copy under a new name.
  """
  @spec worth_saving?([map()]) :: boolean()
  def worth_saving?(turn) do
    names = successful_tool_names(turn)

    length(names) >= @min_tool_calls and
      length(Enum.uniq(names)) >= @min_distinct_tools and
      "skill" not in tool_names(turn)
  end

  @doc """
  The skill this turn should propose an edit to, if any: `{:ok, name}` when a skill
  was read and a *later* tool call in the same turn failed.

  The failure is the whole signal. A skill that was followed and worked teaches
  nothing new - proposing an edit after every successful use would be noise, and the
  agent would have no evidence to edit *with*. A failure afterwards is the opposite:
  the skill's own instructions led somewhere that didn't work, and the correction is
  exactly what the next reader of that skill needs. A turn whose `skill` call itself
  failed (no such skill) is not a candidate - there is nothing to edit. When several
  skills were read, the most recent one before the failure is the one blamed.
  """
  @spec refine_target([map()]) :: {:ok, String.t()} | :none
  def refine_target(turn) do
    args = tool_call_args(turn)

    turn
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Enum.reduce(:none, &advance(&1, &2, args))
    |> case do
      {:failed, skill} -> {:ok, skill}
      _ -> :none
    end
  end

  # Walks this turn's tool results in order, holding one of three states: nothing seen yet,
  # a skill read and so far fine, or that skill followed by a failure.
  defp advance(msg, state, args) do
    case skill_read(msg, args) do
      {:ok, skill} -> {:read, skill}
      :none -> mark_failure(msg, state)
    end
  end

  defp mark_failure(msg, {:read, skill}), do: if(error_result?(msg), do: {:failed, skill}, else: {:read, skill})
  defp mark_failure(_msg, state), do: state

  # Every tool call the assistant made this turn, by id, so a `skill` result can be traced
  # back to *which* skill it read (the result message carries only the tool's name).
  defp tool_call_args(turn) do
    for msg <- turn,
        msg["role"] == "assistant",
        is_list(msg["tool_calls"]),
        call <- msg["tool_calls"],
        into: %{},
        do: {call["id"], get_in(call, ["function", "arguments"])}
  end

  defp skill_read(msg, args) do
    with "skill" <- msg["name"],
         false <- error_result?(msg),
         raw when is_binary(raw) <- Map.get(args, msg["tool_call_id"]),
         {:ok, %{"name" => name}} when is_binary(name) <- Jason.decode(raw) do
      {:ok, name}
    else
      _ -> :none
    end
  end

  defp tool_names(turn), do: for(msg <- turn, msg["role"] == "tool", is_binary(msg["name"]), do: msg["name"])

  defp successful_tool_names(turn),
    do: for(msg <- turn, msg["role"] == "tool", is_binary(msg["name"]), not error_result?(msg), do: msg["name"])

  # `Pepe.Tools.error?/1` owns the prefix every failure path and every permission denial
  # produces; re-deriving it here would silently drift from it.
  defp error_result?(msg), do: is_binary(msg["content"]) and Tools.error?(msg["content"])

  defp save_note do
    """
    <system-reminder>
    This turn took several tool calls to work out. If what you just did is a repeatable
    procedure someone will ask for again, and the non-obvious part was *how* to do it (the
    exact steps, arguments, order, or trap), then end your reply with one short sentence
    offering to save it as a skill, so next time is direct. If it was a one-off, or
    something you would work out from scratch anyway, say nothing about this at all.
    Offer at most once per conversation: if you already offered, or the user already said
    no, drop it. Only if they accept, read the `skill-creator` skill and follow it. Never
    create or change a skill file without an explicit yes. Do not mention this note.
    </system-reminder>
    """
  end

  defp refine_note(skill) do
    """
    <system-reminder>
    You read the `#{skill}` skill this turn and something after it failed. If that failure
    taught you something the skill itself should have said (a missing step, an argument its
    example got wrong, a trap you only hit in practice), end your reply with one short
    sentence offering to update `#{skill}` with it. An edit to that skill, never a new one.
    If nothing durable came out of it (a typo, a one-off environment problem, a failure the
    skill already explains), say nothing about this at all. Only if the user accepts, read
    the `skill-creator` skill and follow its "Edit / audit / tidy" steps, keeping the
    skill's trigger line intact. Never change a skill file without an explicit yes. Do not
    mention this note.
    </system-reminder>
    """
  end
end
