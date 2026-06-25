defmodule Pepe.Agent.Reflect do
  @moduledoc """
  Background self-improvement: after a session, the agent reviews the conversation
  and decides what should become **memory** or a **skill** - writing them itself.

  A background memory/skill review, in Pepe's own terms: a
  *fork* is just an extra `Pepe.Agent.Runtime` run over a copy of the session's
  transcript, with the tool set **restricted to file/skill management** (read, write,
  edit, list, skill) and no human permission prompt - so the review can update the
  workspace on its own but can't run shell/network. The live session and its context
  are untouched. It's opt-in per agent (`learn: true`) and fires on `/compact`, on
  idle, or on demand (`/learn`).

  Two jobs, kept separate (so memory stays about *the user* and skills about
  *technique*), and both told to stay lean - consolidate memory instead of piling
  on, and prefer updating an existing skill over spawning a narrow new one.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Cron
  alias Pepe.LLM.Message

  # Only file + skill management - never bash/network. Runs without the human gate.
  @review_tools ~w(read_file write_file edit_file list_dir skill)

  @default_schedule "0 3 * * *"

  @review_prompt """
  [Background review - the user will NOT see this turn.]

  Look back over the conversation and improve what you've learned, using ONLY your
  file tools. Two separate jobs:

  1) MEMORY - about the user. Did they reveal preferences, persona, personal facts,
     or how they want you to behave/work? If so, record it: append to `USER.md`
     (who they are / how they want you to operate), `MEMORY.md` (durable facts and
     decisions), or `people.md` (someone they mentioned). Write each as a declarative
     FACT about the user, never as an order to yourself: "prefers terse answers", not
     "always answer tersely" - an imperative gets re-read next session as a standing
     instruction and can quietly override what the user actually asks for then. Favour
     what will spare the user from correcting or reminding you again. Keep these files
     LEAN - if one is getting long, consolidate or drop stale lines instead of piling
     on. Save durable preferences and facts, not one-off task status. If there's
     nothing genuinely new, leave memory alone.

  2) SKILLS - about technique. Did a reusable technique, fix, workaround, or a
     correction to your style/workflow/format emerge? Capture it. PREFER updating an
     existing skill (check your skills, edit the one that covers this territory) over
     creating a narrow new one - aim for a few rich skills, not a long flat list.
     Write/edit `skills/<name>.md` with the first line a one-line "use when ..."
     summary. If a skill you used was wrong or missing a step, fix it now.

  Make small, real improvements when warranted; if there is genuinely nothing to
  save or update, do nothing. End with a one-line summary of what you changed (or
  "nothing").
  """

  @doc """
  Review a session transcript and let the agent update its memory/skills. Runs the
  restricted reviewer synchronously; use `review_async/2` to fire-and-forget.
  """
  @spec review(Pepe.Config.Agent.t(), [map()]) :: {:ok, String.t(), [map()]} | {:error, term()}
  def review(agent, messages) do
    reviewer = review_agent(agent)
    transcript = messages ++ [Message.user(@review_prompt)]
    # No `:authorize` -> nobody to prompt on this background surface. The review's whole job is to
    # write to its own memory/skills, so `review_agent/1` pre-approves those file writes; without
    # it they hit the gate with no human to ask and are denied, and the review could read but never
    # save what it learned.
    Runtime.run(reviewer, transcript, [])
  end

  # The reviewer: file/skill tools only, and its own-workspace file writes pre-approved. The bare
  # `write_file`/`edit_file` grants cover a no-risk write (its own workspace); a write to `shared/`
  # or an absolute path still carries a risk hint the grant does not cover, so it stays gated.
  defp review_agent(agent) do
    %{agent | tools: @review_tools, auto_approve: ~w(write_file edit_file), max_iterations: 8}
  end

  @doc "Fire the review in the background - never blocks the caller."
  @spec review_async(Pepe.Config.Agent.t(), [map()]) :: :ok
  def review_async(agent, messages) do
    Task.start(fn -> review(agent, messages) end)
    :ok
  end

  @consolidate_prompt """
  [Background memory maintenance - no user is watching this turn.]

  There is no conversation to learn from here. The job is pure housekeeping over the
  memory and skills you have ALREADY saved, using ONLY your file tools:

  1) Read each knowledge file you keep that exists (`USER.md`, `MEMORY.md`, `people.md`)
     and your skills.
  2) Consolidate: merge entries that duplicate or overlap, drop lines that are stale,
     superseded, or contradicted by a newer one, and tighten wordy entries. Keep every
     durable fact, decision, preference and name - only compress, never lose information.
  3) For skills, prefer merging overlapping ones into a richer skill over keeping many
     narrow files.
  4) Invent nothing. Only reorganize what is already there.

  Make real improvements only where warranted; if everything is already lean, change
  nothing. End with a one-line summary of what you changed (or "nothing").
  """

  @doc """
  Housekeeping pass over an agent's *standing* memory and skills (no transcript): the
  agent re-reads what it has saved and consolidates it. Same restricted, file-only,
  no-gate reviewer as `review/2`. Returns `{:ok, summary, messages}` or `{:error, _}`.
  """
  @spec consolidate(Pepe.Config.Agent.t()) :: {:ok, String.t(), [map()]} | {:error, term()}
  def consolidate(agent) do
    Runtime.converse(review_agent(agent), @consolidate_prompt, review: Config.review_writes?())
  end

  ###
  ### scheduled consolidation - a managed cron that fires `consolidate/1`
  ###

  @doc "The stable id of an agent's managed consolidation cron."
  def auto_cron_id(agent_name), do: "learn:" <> agent_name

  @doc "Is scheduled consolidation on for this agent?"
  def auto?(agent_name), do: not is_nil(Config.get_cron(auto_cron_id(agent_name)))

  @doc "The default consolidation schedule (nightly)."
  def default_schedule, do: @default_schedule

  @doc """
  Turn on scheduled consolidation for an agent: a managed `consolidate` cron. `opts`
  may carry `:schedule` (cron expression) and `:timezone`. Idempotent per agent.
  """
  def schedule_auto(agent_name, opts \\ []) do
    cron = %Cron{
      id: auto_cron_id(agent_name),
      name: "Memory consolidation (#{agent_name})",
      agent: agent_name,
      kind: "consolidate",
      prompt: "",
      schedule: opts[:schedule] || @default_schedule,
      timezone: opts[:timezone] || Config.default_timezone(),
      deliver: "none",
      enabled: true
    }

    Config.put_cron(cron)
    {:ok, cron}
  end

  @doc "Turn off scheduled consolidation for an agent."
  def unschedule_auto(agent_name) do
    Config.delete_cron(auto_cron_id(agent_name))
    :ok
  end
end
