defmodule Pepe.Usage.Prepaid do
  @moduledoc """
  An optional, per-project prepaid balance: real money credited (a payment received, or
  an operator topping a client up by hand), depleted by actual billable spend, gating new
  model calls at zero - a genuine "the agent stops running" limit, unlike
  `Pepe.Config.project_budget/1`'s monthly cap, which resets on its own every month and
  was never meant to model money a client actually paid in.

  A project with no balance ever credited behaves exactly as if this didn't exist - only
  `Pepe.Usage.over_budget?/1`'s monthly cap applies, same as before. The moment something
  credits a project (`credit/2` - the dashboard, the CLI, or the generic payment webhook,
  see `PepeWeb.BalanceWebhookController`), a row exists and `exhausted?/1` starts
  participating in `Pepe.Agent.Runtime`'s pre-flight gate too. A project can have both a
  monthly cap and a prepaid balance; either hitting zero/its ceiling stops new calls.

  `balance`/`settled_through_id` are a checkpoint, not the live number - the real balance
  is always `stored balance - Pepe.Usage.billable_after_id(project, settled_through_id)`,
  computed on read the same way `Pepe.Usage.month_to_date/1` already sums a window of the
  ledger. `credit/2` folds that spend into the checkpoint before adding funds, so the
  stored number never silently drifts from what the ledger says was actually spent.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Usage
  alias Pepe.Usage.Log
  alias Pepe.Usage.PrepaidBalance

  @doc """
  The live balance for `project`, or `nil` if none has ever been credited (prepaid mode
  is simply not in play for this project) - also `nil`, rather than raising, if `Pepe.Repo`
  isn't running at all (a bare `ExUnit.Case` test that never touches operational data is
  the normal case for this; outside tests it's always up - see `Pepe.Repo`'s moduledoc).
  This is checked on *every* run via `Pepe.Agent.Runtime`'s pre-flight gate, so it must
  degrade the same way `Pepe.Trace`/`Pepe.Config.Journal` already tolerate a Repo hiccup,
  never turn a run that never needed a prepaid balance in the first place into a crash.
  """
  @spec balance(String.t() | nil) :: float() | nil
  def balance(project) do
    case get(project) do
      nil -> nil
      row -> row.balance - Usage.billable_after_id(project, row.settled_through_id)
    end
  rescue
    e ->
      Logger.warning("[prepaid] #{Exception.message(e)}")
      nil
  end

  @doc "Has a balance been credited at least once, and is it now at or below zero?"
  @spec exhausted?(String.t() | nil) :: boolean()
  def exhausted?(project) do
    case balance(project) do
      nil -> false
      b -> b <= 0
    end
  end

  @doc """
  Add `amount` (in the billing currency) to `project`'s balance, settling first (folding
  in spend since the last checkpoint) so the stored number stays accurate. Creates the
  row on a project's first-ever credit. Returns the new live balance.
  """
  @spec credit(String.t() | nil, number()) :: {:ok, float()} | {:error, :invalid_amount | :repo_unavailable}
  def credit(_project, amount) when not is_number(amount) or amount <= 0, do: {:error, :invalid_amount}

  def credit(project, amount) do
    do_credit(project, amount)
  rescue
    e ->
      Logger.warning("[prepaid] credit failed: #{Exception.message(e)}")
      {:error, :repo_unavailable}
  end

  defp do_credit(project, amount) do
    name = scope_name(project)
    current = get_by_name(name)
    # Snapshotted first, and used as both the settle sum's upper bound and the new
    # checkpoint - an entry written concurrently, after this line, is simply deferred
    # to the next credit/balance read rather than silently skipped (see
    # Pepe.Usage.Log.entries_after_id/3): it's past the old checkpoint but would also
    # be past a *new* one taken after it already existed, so it must not be excluded
    # from every future settle just because it lost a race with this one.
    up_to_id = Log.latest_id(project)

    settled =
      case current do
        nil -> 0.0
        row -> row.balance - Usage.billable_after_id(project, row.settled_through_id, up_to_id)
      end

    new_balance = settled + amount / 1
    row = %{project: name, balance: new_balance, settled_through_id: up_to_id}

    Repo.insert_all(PrepaidBalance, [row], on_conflict: {:replace, [:balance, :settled_through_id]}, conflict_target: :project)

    {:ok, new_balance}
  end

  defp get(project), do: get_by_name(scope_name(project))
  defp get_by_name(name), do: Repo.one(from(b in PrepaidBalance, where: b.project == ^name))

  defp scope_name(project) when project in [nil, ""], do: Config.default_project_slug()
  defp scope_name(project), do: to_string(project)
end
