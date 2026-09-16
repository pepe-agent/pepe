defmodule Pepe.Permissions.Grants do
  @moduledoc """
  The audit trail behind every standing ("always") permission grant, plus the way to undo
  one (`mix pepe grants list|revoke`).

  `Pepe.Config.allow_tool/2` is the actual trust boundary - the `auto_approve` entry it
  writes is what a later call is checked against. Once written, nothing about who granted
  it, from where, or when survives in `config.json` alone. This ledger is the missing half:
  every call to `grant/5` writes both the config entry (via `allow_tool/2`) and a durable
  `Pepe.Permissions.GrantRecord` row, so a standing grant nobody remembers giving is
  something a human can actually find and undo, not just a line in a file nobody audits.

  ## What revoking actually does

  `auto_approve` is tool-granular, not per-event granular: two "always" grants for the same
  tool (bash:deletes, then later bash:network) fold into one widened entry
  (bash:deletes+network - see `Pepe.Permissions.Grant.merge/2`), and nothing in the config
  says which of the two a human meant to undo. Revoking *either* ledger row for that
  agent+tool strips the tool's *entire* current grant, the safer failure direction
  (over-revoking just means asking again; under-revoking leaves a live standing grant).
  Every other still-active row for the same agent+tool is marked revoked alongside it, so
  `list/1` never shows a grant as "active" once the config no longer honors it.

  Best-effort on the ledger half by design: if `Pepe.Repo` cannot be reached, `grant/5`
  still writes the actual `auto_approve` entry (the part that matters for enforcement) and
  simply skips the audit row, the same "storage hiccup degrades, never blocks the turn"
  posture `Pepe.Permissions.PendingApprovals` already takes.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Pepe.Config
  alias Pepe.Permissions.Grant
  alias Pepe.Permissions.GrantRecord
  alias Pepe.Repo

  @doc """
  Persist `grant` on `agent` and record it. `source` names the surface that produced it
  ("telegram", "web" - the dashboard's own session-key prefix, "approvals", "cli", ...); `granted_by` is the best identity
  available there (typically a session key); `reason` is optional free text. Returns
  whatever `Config.allow_tool/2` returns (`:ok` or `{:error, :unknown_agent}`) - the ledger
  write is best-effort and never changes that outcome.
  """
  @spec grant(String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, :unknown_agent}
  def grant(agent, grant_str, source, granted_by \\ nil, reason \\ nil) do
    with :ok <- Config.allow_tool(agent, grant_str) do
      record(agent, grant_str, source, granted_by, reason)
      :ok
    end
  end

  # Best-effort per the moduledoc - but "best-effort" means degrade loudly, not silently.
  # A swallowed failure here (a ledger id collision, `Pepe.Repo` unreachable, a changeset
  # error) previously vanished with no trace: `Config.allow_tool/2` above still grants the
  # tool, so the turn is unaffected, but the grant is now missing from `mix pepe grants
  # list` with nothing to say why - the same "storage hiccup degrades, never blocks, but
  # still logs" posture `Pepe.Store.safe/2` already uses for its own best-effort writes.
  defp record(agent, grant_str, source, granted_by, reason) do
    result =
      %GrantRecord{}
      |> GrantRecord.changeset(%{
        id: new_id(),
        agent: agent,
        grant: grant_str,
        source: source,
        granted_by: granted_by,
        reason: reason,
        created_at: System.system_time(:second)
      })
      |> Repo.insert()

    case result do
      {:ok, _record} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[grants] could not record ledger row for #{agent}/#{grant_str}: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[grants] could not record ledger row for #{agent}/#{grant_str}: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[grants] could not record ledger row for #{agent}/#{grant_str}: #{inspect(reason)}")
      :ok
  end

  @doc "All grant records, newest first. Pass `agent` to scope to one agent."
  @spec list(String.t() | nil) :: [GrantRecord.t()]
  def list(agent \\ nil) do
    # `created_at` is second-granularity; `:id` (random hex) has no chronological meaning
    # either, but it's a stable, deterministic tiebreaker for two grants written in the
    # same wall-clock second (easy to hit: an approval's grant + its also_grant, back to
    # back - see Pepe.Permissions.PendingApprovals.persist_always/1) instead of leaving
    # `list/1`'s order for those two undefined.
    query = from(g in GrantRecord, order_by: [desc: :created_at, desc: :id])
    query = if agent, do: from(g in query, where: g.agent == ^agent), else: query
    Repo.all(query)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Only the grants still actually in effect: not revoked through here, *and* still present in
  the agent's live `auto_approve` right now. `revoke/2` is not the only way a grant leaves
  `auto_approve` - `/approve clear`, the dashboard's agent editor, `manage_agent`, `mix pepe
  agent`, or a hand edit of `config.json` all rewrite it directly, with no ledger row to
  update. Checking against the config at read time, not trusting `revoked_at` alone, is what
  keeps "active" honest regardless of which of those actually removed it.
  """
  @spec active(String.t() | nil) :: [GrantRecord.t()]
  def active(agent \\ nil) do
    agent
    |> list()
    |> Enum.filter(&(is_nil(&1.revoked_at) and covered_by_config?(&1)))
  end

  defp covered_by_config?(%GrantRecord{agent: agent_name, grant: grant_str}) do
    {tool, _risks} = Grant.parse(grant_str)

    case Config.get_agent(agent_name) do
      nil -> false
      %Config.Agent{auto_approve: auto} -> Enum.any?(auto, &(elem(Grant.parse(&1), 0) in [tool, "*"]))
    end
  end

  @doc "Fetch one record by id, or nil."
  @spec get(String.t()) :: GrantRecord.t() | nil
  def get(id) do
    Repo.get(GrantRecord, id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Revoke the grant `id` recorded: strips the tool's `auto_approve` entry entirely (see
  moduledoc), clears the same tool from `Pepe.Permissions.SessionStore` for every ledger
  row's own `granted_by` (a live session that already said "always" this turn also holds an
  in-memory copy - see `Pepe.Permissions.remember/4` - which a config-only revoke would
  otherwise leave silently covering the tool until `/new` or a restart), and marks every
  active ledger row for that agent+tool as revoked, this one included. Returns `{:ok,
  [revoked_records]}` or `{:error, :not_found | :already_revoked | :unknown_agent |
  :wildcard_grant}`.

  `:unknown_agent` is `Config.revoke_tool/2` itself failing (the agent was deleted or
  renamed since this grant was recorded): no ledger row is touched, since marking rows
  "revoked" while the config write that was supposed to back it up never happened would be
  exactly the stale-ledger problem this feature exists to avoid, just inverted (a
  revoked-looking row over a grant that, if the agent still existed, would still be live).

  `:wildcard_grant` is refused for a different reason: the agent's `auto_approve` holds the
  bare `"*"` (every tool, every risk - the default for a project's first/owner agent).
  Stripping one tool's entry does nothing while `"*"` still covers it, so revoking would
  silently be a no-op even though it reports success; the alternative, stripping `"*"`
  itself, would drop trust for every other tool the operator never asked to touch. Neither
  is what a scoped "revoke this one tool" request should do, so this refuses instead of
  guessing - the fix is for the operator to edit `auto_approve` by hand, replacing `"*"`
  with the specific grants this agent actually needs.
  """
  @spec revoke(String.t(), String.t() | nil) :: {:ok, [GrantRecord.t()]} | {:error, atom()}
  def revoke(id, revoked_by \\ nil) do
    case get(id) do
      nil -> {:error, :not_found}
      %GrantRecord{revoked_at: at} when not is_nil(at) -> {:error, :already_revoked}
      %GrantRecord{} = record -> do_revoke(record, revoked_by)
    end
  end

  defp do_revoke(%GrantRecord{agent: agent, grant: grant_str}, revoked_by) do
    {tool, _risks} = Grant.parse(grant_str)

    case Config.get_agent(agent) do
      nil -> {:error, :unknown_agent}
      %Config.Agent{} = agent_struct -> revoke_by_tool(agent_struct, agent, tool, revoked_by)
    end
  end

  defp revoke_by_tool(%Config.Agent{auto_approve: auto}, agent, tool, revoked_by) do
    if Enum.any?(auto, &Grant.wildcard?/1) do
      {:error, :wildcard_grant}
    else
      # Computed BEFORE the config write below, deliberately: active/1 reconciles against
      # the live config, and once Config.revoke_tool/2 strips the tool's entry, every ledger
      # row for it would stop looking "active" and this would find nothing left to mark
      # revoked - even though the write it's supposed to be recording just succeeded.
      # `record` itself is necessarily among these: it was just read with revoked_at == nil,
      # which is exactly active/1's filter, for this same agent+tool.
      siblings = agent |> active() |> Enum.filter(fn r -> elem(Grant.parse(r.grant), 0) == tool end)

      with :ok <- Config.revoke_tool(agent, tool), do: finish_revoke(siblings, tool, revoked_by)
    end
  end

  defp finish_revoke(siblings, tool, revoked_by) do
    now = System.system_time(:second)

    # Each sibling's own `granted_by` (a session key for the telegram/dashboard/approvals
    # sources - see Pepe.Permissions.remember/4 and PendingApprovals.persist_always/1; nil
    # or "cli" for a CLI-originated grant, which SessionStore.disallow/2 just no-ops on).
    Enum.each(siblings, &Pepe.Permissions.SessionStore.disallow(&1.granted_by, tool))

    Repo.transaction(fn ->
      Enum.map(siblings, fn r ->
        {:ok, updated} =
          r
          |> GrantRecord.changeset(%{revoked_at: now, revoked_by: revoked_by})
          |> Repo.update()

        updated
      end)
    end)
  end

  defp new_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
