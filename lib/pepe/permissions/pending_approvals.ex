defmodule Pepe.Permissions.PendingApprovals do
  @moduledoc """
  The lifecycle of a `Pepe.Permissions.PendingApproval`: park, list, approve, deny.

  `park/4` is called by `Pepe.Permissions.gate/3` at the exact spot that used to be a
  permanent refusal - "this call needs a human's OK and there is no `authorize` callback
  to render a prompt with". Instead of failing closed forever, the call is stored and
  the model is told, in the denial itself, the literal command a human can later type.

  `approve/2` is the delayed half of the same decision an attended prompt makes live:
  it re-runs the **stored** call through `Pepe.Tools.execute/2` (the same replay
  `Pepe.Approval.approve/1` already does for staged writes - the human approved *this*
  call, so it runs as-is, not through the gate again), then hands the result back into
  the owning session as a new turn. That hand-off reuses the exact mechanism
  `Pepe.Commitments.Scheduler.fulfill/1` already uses to deliver an `agent_promise`:
  `Pepe.Agent.SessionSupervisor.ensure/2` + `Pepe.Agent.Session.chat/3` with an internal
  note the user never sees, and the agent's own genuine reply is what gets delivered to
  the origin channel via `Pepe.Watch.Delivery`. No model retry of the tool call is
  needed - the result is already in the note.

  `deny/2` delivers the refusal the same way, optionally carrying the human's free-text
  reason so the model hears *why*, not just "no".

  ## Expiry

  A record is good for `ttl_s/0` seconds (30 minutes by default, `:pending_approval_ttl_s`
  in the app env to override - same lightweight dial as `:telegram_perm_timeout_ms`).
  Expiry is computed **lazily at read time** rather than by a sweeper: unlike
  `Pepe.Agent.MicroCompaction`'s ETS cache (unbounded memory that must be actively
  pruned), an expired approval is *meaningful state a human should still see* in
  `list/0` ("you missed this one"), and correctness only requires that approve/deny
  refuse to act on one - both checked at action time. A resolve attempt on an expired
  record persists the flip to `"expired"`; old resolved records are pruned on the next
  `park/4` so the table stays bounded without a scheduler.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Agent.Runtime
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Permissions.Grant
  alias Pepe.Permissions.PendingApproval
  alias Pepe.Repo
  alias Pepe.Watch.Delivery

  @default_ttl_s 30 * 60
  # Resolved/expired records older than this are dropped on the next park - long enough
  # to audit "what happened while I was away", short enough that the table never grows
  # with usage the way the compaction store once did.
  @keep_resolved_s 7 * 24 * 60 * 60

  @doc "How long a pending approval stays answerable, in seconds (default 30 minutes)."
  @spec ttl_s() :: integer()
  def ttl_s, do: Application.get_env(:pepe, :pending_approval_ttl_s, @default_ttl_s)

  @doc """
  Park a would-ask call that had nobody to ask. Returns `{:ok, record}` or
  `:unavailable` when the store cannot be reached (`Pepe.Repo` not running - a bare
  library-style embedding, or a test that never started it), in which case the gate
  falls back to the plain unattended refusal. Best-effort on purpose: the gate runs
  inside the turn's own process, and a storage hiccup must degrade to the old behavior,
  never crash the turn or - worse - let the call through.
  """
  @spec park(String.t(), term(), [Pepe.Permissions.Risk.kind()], map()) ::
          {:ok, PendingApproval.t()} | :unavailable
  def park(tool, args, risks, ctx) do
    now = System.system_time(:second)

    record = %PendingApproval{
      id: new_id(),
      tool: tool,
      args: Pepe.Permissions.decode(args),
      session_key: if(is_binary(ctx[:session_key]), do: ctx[:session_key]),
      agent: agent_name(ctx),
      origin: Delivery.origin_from_ctx(ctx),
      # Precomputed here, where the gate's view of the call is still in hand, so an
      # `--always` approval later persists exactly what an attended `:always` would have
      # (including a policy-forced ask's own namespaced key - see Pepe.Permissions).
      grant: Grant.for(ctx[:grant_key] || tool, risks),
      also_grant: if(also = ctx[:also_grant], do: Grant.for(also, risks)),
      tainted: Pepe.Permissions.tainted?(ctx),
      status: "pending",
      created_at: now,
      expires_at: now + ttl_s()
    }

    prune(now)

    case Repo.insert(PendingApproval.changeset(record, %{})) do
      {:ok, saved} -> {:ok, saved}
      {:error, _changeset} -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "All records, newest first, with a stale `pending` read back as `expired`."
  @spec list() :: [PendingApproval.t()]
  def list do
    PendingApproval
    |> from(order_by: [desc: :created_at])
    |> Repo.all()
    |> Enum.map(&effective/1)
  end

  @doc "Fetch one record by id (status corrected for expiry), or nil."
  @spec get(String.t()) :: PendingApproval.t() | nil
  def get(id) do
    case Repo.get(PendingApproval, id) do
      nil -> nil
      record -> effective(record)
    end
  end

  @doc """
  Approve a pending record: run the exact stored call, optionally persist an `always`
  grant on the agent (`always: true` - the same `Pepe.Config.allow_tool/2` write an
  attended `:always` answer makes), and deliver the result back into the owning session
  as a new turn. Returns `{:ok, result, delivery}` where `delivery` is `:delivered`,
  `:no_session`, or `{:undelivered, reason}`; or `{:error, :not_found | :expired |
  {:already, status} | {:agent_missing, name}}`.

  The record is marked `approved` *before* the call runs, mirroring
  `Pepe.Commitments.Scheduler`'s persist-"firing"-first contract: running the call can
  take real time and have real side effects, and a crash partway through must read as
  "was approved, may have run" - never as still-answerable, which could run it twice.
  That marking is a single atomic compare-and-swap on `status == "pending"` (see
  `claim/3`), so N concurrent resolvers of the same id produce exactly one winner:
  only the winner runs the stored call or delivers anything, every loser is told what
  beat it and touches nothing.

  If the agent the record was parked for no longer exists (deleted or renamed since
  park time), the approval is refused with `{:error, {:agent_missing, name}}` and
  nothing runs: replaying the call with `agent: nil` would resolve its working
  directory to the operator's own shell instead of any agent's workspace, and would
  silently drop an `--always` grant. The record stays pending, so it can still be
  denied, or approved once the agent exists again.
  """
  @spec approve(String.t(), keyword()) ::
          {:ok, String.t(), :delivered | :no_session | {:undelivered, term()}}
          | {:error, :not_found | :expired | {:already, String.t()} | {:agent_missing, String.t()}}
  def approve(id, opts \\ []) do
    with {:ok, pending} <- resolvable(id),
         {:ok, agent} <- stored_agent(pending),
         {:ok, record} <- claim(id, "approved", nil) do
      if opts[:always], do: persist_always(record)
      result = run_stored_call(record, agent)
      # An approved fetch_url/web_search/db_query/delegate/MCP call hands back content
      # from outside - the resumed turn must be born tainted (`:untrusted`), exactly as
      # the rest of an attended run would have been had the call run inline. Without
      # this, approving such a call would give the follow-up turn MORE privilege than
      # the inline path: stranger content in context with auto_approve still live.
      untrusted? = Runtime.outside_content?(record.tool)
      {:ok, result, hand_back(record, approved_note(record, result), untrusted: untrusted?)}
    end
  end

  @doc """
  Deny a pending record, optionally with the human's free-text `reason` - relayed
  verbatim to the model in the note that resumes the session, so the agent hears *why*
  and can adjust instead of guessing. Resolution is the same atomic claim `approve/2`
  makes - concurrent resolvers get exactly one winner. Returns `{:ok, record,
  delivery}` or the same errors as `approve/2`, minus `{:agent_missing, name}`:
  refusing runs nothing, so a vanished agent never blocks a deny.
  """
  @spec deny(String.t(), String.t() | nil) ::
          {:ok, PendingApproval.t(), :delivered | :no_session | {:undelivered, term()}}
          | {:error, :not_found | :expired | {:already, String.t()}}
  def deny(id, reason \\ nil) do
    with {:ok, _pending} <- resolvable(id),
         {:ok, record} <- claim(id, "denied", reason) do
      {:ok, record, hand_back(record, denied_note(record, reason))}
    end
  end

  ###
  ### internals
  ###

  # Still answerable? An expired record is flipped to "expired" on the spot (so the
  # missed one reads as missed from then on, in the DB too, not just in list/0's lazy
  # view) and reported as such rather than half-acted-on. This is only a best-effort
  # *read* for accurate error reporting - the authoritative once-only decision is
  # claim/3's compare-and-swap, never this check.
  defp resolvable(id) do
    case Repo.get(PendingApproval, id) do
      nil ->
        {:error, :not_found}

      %PendingApproval{status: "pending"} = record ->
        if expired?(record) do
          expire(record)
          {:error, :expired}
        else
          {:ok, record}
        end

      %PendingApproval{status: status} ->
        {:error, {:already, status}}
    end
  end

  # The at-most-once gate: a single atomic compare-and-swap on `status == "pending"`,
  # not a read-check-then-write (which let N concurrent resolvers all pass the check
  # and run the stored call N times). Exactly one caller ever sees `count == 1`; only
  # that winner may run the call, persist a grant, or deliver - a loser gets the
  # outcome that beat it and must not touch anything. The expiry guard rides in the
  # same WHERE clause so a record cannot be claimed in the same instant it lapses.
  defp claim(id, status, reason) do
    now = System.system_time(:second)

    {count, _} =
      from(p in PendingApproval,
        where: p.id == ^id and p.status == "pending",
        where: is_nil(p.expires_at) or p.expires_at >= ^now
      )
      |> Repo.update_all(set: [status: status, reason: reason, resolved_at: now])

    if count == 1, do: {:ok, Repo.get!(PendingApproval, id)}, else: lost_claim(id)
  end

  # The CAS matched nothing: someone else resolved the record first, it lapsed, or it
  # was pruned. Re-read to report which - without ever re-claiming.
  defp lost_claim(id) do
    case Repo.get(PendingApproval, id) do
      nil ->
        {:error, :not_found}

      %PendingApproval{status: "pending"} = record ->
        # Still pending yet unclaimable: only claim/3's expiry guard can have excluded
        # it (time moves one way, so it is expired now too). Persist the flip.
        expire(record)
        {:error, :expired}

      %PendingApproval{status: status} ->
        {:error, {:already, status}}
    end
  end

  # Persist a lapsed pending record as "expired" - itself a CAS on `status ==
  # "pending"`, so it can never overwrite a concurrent approve/deny that won first.
  defp expire(%PendingApproval{id: id}) do
    from(p in PendingApproval, where: p.id == ^id and p.status == "pending")
    |> Repo.update_all(set: [status: "expired", resolved_at: System.system_time(:second)])

    :ok
  end

  # The agent a record was parked for can be deleted or renamed between park and
  # approve. Running anyway would pass `agent: nil` into the tool ctx, and the
  # workspace-first cwd resolution would fall back to the operator's own current
  # directory - an unscoped place no agent sandbox ever pointed at - while an
  # `--always` grant would be silently dropped. Refuse instead; the record stays
  # pending. Resolved here, before the claim, so a refusal costs nothing.
  defp stored_agent(%PendingApproval{agent: nil}), do: {:ok, nil}

  defp stored_agent(%PendingApproval{agent: name}) do
    case Config.get_agent(name) do
      nil -> {:error, {:agent_missing, name}}
      agent -> {:ok, agent}
    end
  end

  defp expired?(%PendingApproval{expires_at: at}, now \\ System.system_time(:second)),
    do: is_integer(at) and now > at

  defp effective(%PendingApproval{status: "pending"} = record) do
    if expired?(record), do: %{record | status: "expired"}, else: record
  end

  defp effective(record), do: record

  # The human approved THIS call, so it runs as-is - through the same replay
  # `Pepe.Approval.approve/1` uses for staged writes (Pepe.Tools.execute/2, so
  # redaction/secret-scrubbing/spilling all apply), not through the gate again.
  #
  # A tainted record re-imposes its taint around the replay: the CLI process starts
  # untainted, and for most tools that's moot (the gate isn't consulted again), but a
  # replayed `run_code` script gates every in-script `pepe_call` fresh - untainted,
  # those inner calls would enjoy the auto_approve the original attempt had already
  # lost, i.e. the replay would run with MORE privilege than what the human saw parked.
  # Snapshot/restore so the taint never leaks into the resolving process's later work.
  defp run_stored_call(record, agent) do
    call = %{"function" => %{"name" => record.tool, "arguments" => record.args}}
    saved = Pepe.Permissions.snapshot()
    if record.tainted, do: Pepe.Permissions.taint()

    try do
      Pepe.Tools.execute(call, %{
        agent: agent,
        cwd: File.cwd!(),
        session_key: record.session_key
      })
    after
      Pepe.Permissions.restore(saved)
    end
  end

  defp persist_always(%PendingApproval{agent: agent} = record) when is_binary(agent) do
    if Config.get_agent(agent) do
      Config.allow_tool(agent, record.grant)
      # A policy-forced ask whose underlying call had no grant of its own recorded a
      # second key at park time - persist both, exactly as an attended `:always` does.
      if record.also_grant, do: Config.allow_tool(agent, record.also_grant)
    end

    :ok
  end

  defp persist_always(_record), do: :ok

  # Deliver the outcome back into the owning conversation as a new turn - the same
  # mechanism Pepe.Commitments.Scheduler.fulfill/1 uses for an agent_promise: ensure the
  # session, run an internal note through Session.chat/3 (the note tells the model the
  # user never sees it), and route the agent's own genuine reply to the origin channel.
  defp hand_back(record, note, opts \\ [])

  defp hand_back(%PendingApproval{session_key: key} = record, note, opts) when is_binary(key) do
    with {:ok, _pid} <- SessionSupervisor.ensure(key, record.agent),
         {:ok, reply} <- Session.chat(key, note, untrusted: opts[:untrusted] == true) do
      case Delivery.deliver(record.origin || %{}, reply) do
        :ok -> :delivered
        {:error, reason} -> {:undelivered, reason}
      end
    else
      error -> {:undelivered, error}
    end
  end

  defp hand_back(_record, _note, _opts), do: :no_session

  defp approved_note(record, result) do
    """
    [Approval update - the user does not see this note, only the reply you send now.]

    Earlier, your `#{record.tool}` call could not run because nobody was around to authorize it, \
    and it was parked for approval (id #{record.id}). A human has now APPROVED it, and the exact \
    stored call was executed. Its result:

    #{result}

    Treat this as that tool call's real result - do not run the same call again. Pick the task \
    back up from here and reply to the user with where things stand.
    """
  end

  defp denied_note(record, reason) do
    why =
      if is_binary(reason) and reason != "",
        do: ", with the reason: \"#{reason}\"",
        else: " (no reason given)"

    """
    [Approval update - the user does not see this note, only the reply you send now.]

    Earlier, your `#{record.tool}` call could not run because nobody was around to authorize it, \
    and it was parked for approval (id #{record.id}). A human has now DENIED it#{why}. Do not run \
    that call again. Adjust your approach accordingly and reply to the user with where things stand.
    """
  end

  defp agent_name(%{agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_ctx), do: nil

  # Short enough to type into a CLI command, random enough to never collide in a table
  # this small - the same shape as Pepe.Approval's staged-write ids.
  defp new_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Lazy retention, run on the write path (park/4): drop resolved/expired records past
  # the audit window. Pending-but-stale rows are kept - they still need to read as
  # "expired" in list/0 until they age past the same window as everything else.
  defp prune(now) do
    cutoff = now - @keep_resolved_s
    from(p in PendingApproval, where: p.created_at < ^cutoff) |> Repo.delete_all()
    :ok
  end
end
