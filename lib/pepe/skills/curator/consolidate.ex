defmodule Pepe.Skills.Curator.Consolidate do
  @moduledoc """
  The curator's model pass: merge overlapping agent-written skills into broader ones.

  A run of the restricted reviewer (`Pepe.Skills.Reviewer`, skills scope, the agent's
  `utility_model` when one is set) is handed the list of skills it may change, with how often
  each was used, and told to fold narrow siblings into a class-level "umbrella" skill (the
  detail moving into `references/`, `templates/` or `scripts/` files of the umbrella) and then
  retire the ones it absorbed. Everything goes through `skill_manage`, so each step is owned,
  scanned, snapshotted and in the ledger under the actor `curator`; a run that merges nothing
  is a good run.

  A dry run holds no write tool at all (`read_only: true`), so it can only describe what it
  would do. What a real run did is read back from the ledger, not from what the model says it
  did.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Skills.Curator
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Reviewer
  alias Pepe.Skills.Stat

  @min_skills 2
  @iterations 16

  @doc """
  Run the pass. Options: `dry_run` (default `false`). Returns a report map with string keys:
  `"ran"`, `"summary"`, and for a run that happened `"model_summary"`, `"changed"` and
  `"archived"`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    dry? = opts[:dry_run] == true
    skills = Curator.candidates()

    cond do
      length(skills) < @min_skills -> skipped("fewer than #{@min_skills} agent-written skills, nothing to merge")
      is_nil(Config.default_agent()) -> skipped("no agent configured to run the pass")
      true -> consolidate(Config.default_agent(), skills, dry?)
    end
  end

  defp skipped(why), do: %{"ran" => false, "summary" => "consolidation skipped: " <> why}

  defp consolidate(agent, skills, dry?) do
    since = System.system_time(:microsecond)
    reviewer = Reviewer.agent(agent, :skills, read_only: dry?, max_iterations: @iterations)

    result = Reviewer.with_run("curator", fn run_opts -> Runtime.converse(reviewer, prompt(skills, dry?), run_opts) end)

    case result do
      {:ok, text, _messages} -> report(text, dry?, since)
      {:error, reason} -> %{"ran" => false, "summary" => "consolidation failed: #{inspect(reason)}"}
    end
  end

  defp report(text, true, _since),
    do: %{
      "ran" => true,
      "dry_run" => true,
      "summary" => "consolidation dry run: see the proposal below",
      "model_summary" => text,
      "changed" => [],
      "archived" => []
    }

  defp report(text, false, since) do
    events = Ledger.since(since, "curator")
    archived = for e <- events, e.action == "archive", do: %{"name" => e.skill, "into" => Ledger.detail(e)["absorbed_into"]}
    changed = for e <- events, e.action in ~w(create edit patch write_file remove_file), do: %{"action" => e.action, "name" => e.skill}

    %{
      "ran" => true,
      "dry_run" => false,
      "summary" => "consolidation: #{length(archived)} skill(s) merged and archived, #{length(changed)} change(s) to skills",
      "model_summary" => text,
      "changed" => changed,
      "archived" => archived
    }
  end

  @doc false
  @spec prompt([Stat.t()], boolean()) :: String.t()
  def prompt(skills, dry?) do
    """
    [Background skill maintenance - no user is watching this turn.]

    You are curating the library of skills that agents wrote for themselves. The goal is a
    library of class-level skills, each one broad enough to cover a whole family of tasks,
    not a pile of narrow ones that each cover one session.

    The skills below are the ONLY ones you may change (everything else belongs to a person, was
    installed, or is protected, and a change to it will be refused):

    #{Enum.map_join(skills, "\n", &line/1)}

    Do this, in order:

    1) Open each skill with `skill` before you change it. Look for skills that cover the same
       family of tasks under different names, or whose bodies overlap.
    2) For each family, pick (or create) ONE umbrella skill with a class-level name. Patch its
       body with the shared procedure, and move the detail of the others into support files of
       the umbrella (`write_file` under `references/`, `templates/` or `scripts/`), so nothing
       is lost: a merged skill's specifics must still be reachable from the umbrella.
    3) Only then retire each absorbed skill with `skill_manage` action `delete` and
       `absorbed_into` set to the umbrella. Archiving is recoverable; a person can restore it.
    4) Rarely used skills that stand alone are fine. Do not merge skills that merely look
       alike but do different jobs. If nothing needs merging, change nothing.
    5) Invent nothing. Only reorganize what is already there.

    #{if dry?, do: "This is a DRY RUN: you hold no write tool. Describe exactly which skills you would merge into which umbrella, and what would move where. Do not pretend you changed anything.\n", else: ""}End with a short summary: the merges you made (or would make), or "nothing".
    """
  end

  defp line(%Stat{} = s) do
    "- #{s.name} (used #{s.use_count} times, opened #{s.view_count}, edited #{s.patch_count}, state #{s.state})"
  end
end
