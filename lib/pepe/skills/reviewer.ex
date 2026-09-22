defmodule Pepe.Skills.Reviewer do
  @moduledoc """
  The restricted agent that maintains memory and skills with nobody present, shared by the
  background review (`Pepe.Agent.Reflect`) and the curator (`Pepe.Skills.Curator`).

  Three things are decided here so the two callers cannot drift apart:

    * **What it may call.** Only file tools for memory, and `skill`/`skill_manage` for
      skills. Never `bash`, the network, config or anything that reaches another surface.
      A skill is written *only* through `skill_manage`: the grant a run gets covers the
      `writes_skill` risk of that tool and nothing for the file tools, so a `write_file`
      into `skills/` stops at the gate (nobody to ask) instead of walking around ownership,
      the read-before-write rule, the scan and the ledger.
    * **What model it runs on.** The agent's `utility_model` when one is configured (a
      review is background work, not the conversation), else the agent's own.
    * **Which run it is.** Every run gets an id the runtime carries as `:review_run`; that is
      what tells `Pepe.Skills.Manage` nobody is present and what `Pepe.Skills.Tracker` keys
      its read marks on.
  """

  alias Pepe.Agent.Utility
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Skills.Tracker

  @type scope :: :all | :memory | :skills

  @tools %{
    all: ~w(read_file write_file edit_file list_dir skill skill_manage),
    memory: ~w(read_file write_file edit_file list_dir),
    skills: ~w(read_file list_dir skill skill_manage)
  }

  @grants %{
    all: ~w(write_file:writes_file edit_file:writes_file skill_manage:writes_skill),
    memory: ~w(write_file:writes_file edit_file:writes_file),
    skills: ~w(skill_manage:writes_skill)
  }

  @default_iterations 8

  @doc "The tool names a run of `scope` holds."
  @spec tools(scope()) :: [String.t()]
  def tools(scope), do: Map.fetch!(@tools, scope)

  @doc """
  The agent a maintenance run executes as. Options: `:max_iterations` (default #{@default_iterations}),
  `model: :agent` to ignore the utility model, and `read_only: true` to drop every write tool.
  """
  @spec agent(Agent.t(), scope(), keyword()) :: Agent.t()
  def agent(%Agent{} = agent, scope, opts \\ []) do
    %{
      agent
      | tools: tools_for(scope, opts[:read_only] == true),
        auto_approve: if(opts[:read_only] == true, do: [], else: Map.fetch!(@grants, scope)),
        max_iterations: Keyword.get(opts, :max_iterations, @default_iterations),
        model: model_for(agent, opts[:model])
    }
  end

  # A read-only run (a curator dry run) simply does not hold the write tools, so "report only"
  # is a fact about the run and not an instruction it could ignore.
  defp tools_for(scope, true), do: tools(scope) -- ~w(write_file edit_file skill_manage)
  defp tools_for(scope, false), do: tools(scope)

  defp model_for(agent, :agent), do: agent.model

  defp model_for(agent, _) do
    if Utility.model(agent), do: agent.utility_model, else: agent.model
  end

  @doc """
  Run `fun` with the runtime options that make a run a background maintenance one, then drop
  its read marks. `actor` is who the ledger names ("review", "curator").
  """
  @spec with_run(String.t(), (keyword() -> result)) :: result when result: term()
  def with_run(actor, fun) do
    run = "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    try do
      fun.(review_run: run, review_actor: actor, review: Config.review_writes?())
    after
      Tracker.forget_run(run)
    end
  end
end
