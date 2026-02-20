defmodule Pepe.Agent.Reflect do
  @moduledoc """
  Background self-improvement: after a session, the agent reviews the conversation
  and decides what should become **memory** or a **skill** — writing them itself.

  A background memory/skill review, in Pepe's own terms: a
  *fork* is just an extra `Pepe.Agent.Runtime` run over a copy of the session's
  transcript, with the tool set **restricted to file/skill management** (read, write,
  edit, list, skill) and no human permission prompt — so the review can update the
  workspace on its own but can't run shell/network. The live session and its context
  are untouched. It's opt-in per agent (`learn: true`) and fires on `/compact`, on
  idle, or on demand (`/learn`).

  Two jobs, kept separate (so memory stays about *the user* and skills about
  *technique*), and both told to stay lean — consolidate memory instead of piling
  on, and prefer updating an existing skill over spawning a narrow new one.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.LLM.Message

  # Only file + skill management — never bash/network. Runs without the human gate.
  @review_tools ~w(read_file write_file edit_file list_dir skill)

  @review_prompt """
  [Background review — the user will NOT see this turn.]

  Look back over the conversation and improve what you've learned, using ONLY your
  file tools. Two separate jobs:

  1) MEMORY — about the user. Did they reveal preferences, persona, personal facts,
     or how they want you to behave/work? If so, record it: append to `USER.md`
     (who they are / how they want you to operate), `MEMORY.md` (durable facts and
     decisions), or `people.md` (someone they mentioned). Keep these files LEAN — if
     one is getting long, consolidate or drop stale lines instead of piling on. If
     there's nothing genuinely new, leave memory alone.

  2) SKILLS — about technique. Did a reusable technique, fix, workaround, or a
     correction to your style/workflow/format emerge? Capture it. PREFER updating an
     existing skill (check your skills, edit the one that covers this territory) over
     creating a narrow new one — aim for a few rich skills, not a long flat list.
     Write/edit `skills/<name>.md` with the first line a one-line "use when …"
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
    reviewer = %{agent | tools: @review_tools, max_iterations: 8}
    transcript = messages ++ [Message.user(@review_prompt)]
    # No `:authorize` → the review's restricted, file-only tools run without prompting.
    Runtime.run(reviewer, transcript, [])
  end

  @doc "Fire the review in the background — never blocks the caller."
  @spec review_async(Pepe.Config.Agent.t(), [map()]) :: :ok
  def review_async(agent, messages) do
    Task.start(fn -> review(agent, messages) end)
    :ok
  end
end
