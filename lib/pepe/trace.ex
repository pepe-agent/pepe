defmodule Pepe.Trace do
  @moduledoc """
  A durable record of what an agent run actually did, for inspection and replay.

  Every top-level run (from any surface: CLI, HTTP, WebSocket, Telegram, cron) writes
  one JSON file under `<PEPE_HOME>/data/traces/<scope>/<id>.json`, holding the outcome,
  timing, token usage and the ordered stream of what happened: the tool calls with
  their arguments, each tool result, denials, failovers and the final reply.

  The run's own process accumulates events in the process dictionary while it runs (the
  runtime tees every lifecycle event here through `event/1`), then `finish/1` writes the
  file once. A sub-agent run nested in the same process folds its events into the
  outer trace instead of starting a second one, so a trace shows the whole tree of work.

  Traces are capped per scope (the oldest are trimmed) so the table stays bounded.
  They are diagnostic, not a billing record - that is `Pepe.Usage.Log`.

  Backed by `Pepe.Repo` (SQLite), not one JSON file per run - see `Pepe.Config.Journal`'s
  moduledoc for the same reasoning (this codebase's other operational subsystems moved
  the same way). Every public function here still takes/returns the exact same
  string-keyed maps the old JSON files held; the atom/string boundary conversion happens
  entirely inside this module, invisible to every caller (the runtime, the dashboard, the
  CLI, `Pepe.Eval.FromTrace`).
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Project
  alias Pepe.Repo
  alias Pepe.Trace.Trace

  @key :pepe_trace
  @keep 200
  @clip 4_000

  # --- recording (called from the runtime, inside the run's own process) -------------

  @doc """
  Begin accumulating a trace for this process. Returns `:started` for the outermost run
  (the one that owns the trace and must call `finish/1`) or `:nested` for a sub-agent run
  sharing the same process, whose events fold into the outer trace.
  """
  def start(agent_name, session, prompt \\ nil, source \\ nil) do
    case Process.get(@key) do
      nil ->
        Process.put(@key, %{
          id: new_id(),
          at: System.os_time(:second),
          agent: agent_name,
          scope: Project.of(agent_name),
          session: session,
          source: source || source_from_session(session),
          prompt: clip(prompt),
          t0: System.monotonic_time(:millisecond),
          events: []
        })

        :started

      _ ->
        :nested
    end
  end

  @doc """
  What triggered a run, derived from its session key. Channel sessions carry their
  surface as the first segment (`telegram:...`, `api:...`, `chatwoot:...`); a stateless
  run (cron, eval, CLI) has no session and passes its source explicitly instead.
  """
  def source_from_session(key) when is_binary(key) and key != "",
    do: key |> String.split(":", parts: 2) |> hd()

  def source_from_session(_), do: "manual"

  @doc """
  Replace the in-progress trace's recorded prompt (no-op if none) - for a caller
  that must `start/4` before it has the final prompt text (e.g. Pepe.Agent.Session
  starting the trace before inbound hooks redact it, so hook activity itself gets
  recorded too), then corrects it once available. The very first `start/4` call
  still decides ownership; this only ever touches the `prompt` field.
  """
  def set_prompt(prompt) do
    case Process.get(@key) do
      nil -> :ok
      t -> Process.put(@key, %{t | prompt: clip(prompt)})
    end

    :ok
  end

  @doc "Append one runtime lifecycle event to the in-progress trace (no-op if none)."
  def event(ev) do
    case {Process.get(@key), encode_event(ev)} do
      {nil, _} -> :ok
      {_, nil} -> :ok
      {t, e} -> Process.put(@key, %{t | events: [e | t.events]})
    end

    :ok
  end

  @doc "Persist the accumulated trace for this process and clear it. Returns the id."
  def finish(result) do
    case Process.get(@key) do
      nil ->
        :ok

      t ->
        Process.delete(@key)

        row = %{
          id: t.id,
          scope: scope_name(t.scope),
          at: t.at,
          agent: t.agent,
          session: t.session,
          source: t.source,
          prompt: t.prompt,
          ms: System.monotonic_time(:millisecond) - t.t0,
          outcome: outcome(result),
          events: Enum.reverse(t.events)
        }

        write(row)
        t.id
    end
  rescue
    # A trace is diagnostic, not the run it's describing - the run itself already
    # finished by the time this executes, so a Repo hiccup here must never turn an
    # already-successful run into a crash. Silent was the wrong choice, though: unlike
    # `Pepe.Config.Journal.record/4`'s equivalent rescue, this one used to swallow the
    # error with no trace of it anywhere, which made a genuinely broken trace pipeline
    # indistinguishable from one quietly working - logged now, same as the journal's.
    e -> Logger.warning("[trace] #{Exception.message(e)}")
  end

  # --- reading (dashboard / CLI) -----------------------------------------------------

  @doc """
  Re-point every trace recorded under `old` (a project slug) to `new` - called on a
  project rename (`Pepe.Config.rename_project/2`) so a project's trace history follows
  it, the same way its workspace directory does.
  """
  @spec rescope_project(String.t(), String.t()) :: :ok
  def rescope_project(old, new) do
    from(t in Trace, where: t.scope == ^old) |> Repo.update_all(set: [scope: new])
    :ok
  end

  @doc """
  Whether `scope` has any traces at all, ever - see
  `Pepe.Usage.Log.any_for_project?/1`'s moduledoc for why `Pepe.Config.rename_project/2`
  checks this against the new slug before renaming. Traces carry real conversation
  content (prompts, tool arguments/results), so this matters even more here than for the
  aggregate usage/message counters - a merge would mix one tenant's actual transcripts
  into another's history, not just a number.
  """
  @spec any_for_scope?(String.t() | nil) :: boolean()
  def any_for_scope?(scope) do
    name = scope_name(scope)
    from(t in Trace, where: t.scope == ^name) |> Repo.exists?()
  end

  @doc "Scopes (projects + root) that have any recorded trace."
  def scopes do
    from(t in Trace, distinct: true, select: t.scope, order_by: t.scope) |> Repo.all()
  end

  @doc """
  Recent traces for a scope, newest first, without their event stream (a light list for
  the index). `limit` caps how many are returned.
  """
  def recent(scope, limit \\ 50) do
    from(t in Trace, where: t.scope == ^scope, order_by: [desc: t.at], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&summarize/1)
  end

  @doc "Load one full trace (with its events) by id, or `nil` if it is gone."
  def get(scope, id) do
    case Repo.get_by(Trace, scope: scope, id: id) do
      nil -> nil
      entry -> to_map(entry)
    end
  end

  @doc """
  Every trace recorded under one session key, oldest first (the order a conversation
  actually happened in) - the turn-by-turn history behind a session, once its own
  process (and any crash-recovery mirror `Pepe.Agent.SessionPersistence` keeps) is gone.
  Light list, same shape as `recent/2` (no event stream).
  """
  @spec for_session(String.t(), String.t(), pos_integer()) :: [map()]
  def for_session(scope, session, limit \\ 200) do
    from(t in Trace, where: t.scope == ^scope and t.session == ^session, order_by: [asc: t.at], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&summarize/1)
  end

  @doc """
  Distinct session keys with at least one trace in `scope`, newest activity first, each
  with its turn count and last-seen time - "what conversations have happened here."
  `nil`/blank session keys (a one-shot CLI run, a cron, anything with no session) are
  excluded: there is nothing to list a "session" for. `session`, when given, restricts
  this to just that one session key - filtered at the query level (not after `limit` is
  already applied), so `Pepe.Tools.SessionSearch`'s own-session-only default still finds
  a session whose own activity is older than `limit` other sessions' more recent ones.
  """
  @spec sessions(String.t(), pos_integer(), String.t() | nil) :: [map()]
  def sessions(scope, limit \\ 50, session \\ nil) do
    from(t in Trace, where: t.scope == ^scope and not is_nil(t.session) and t.session != "")
    |> maybe_filter_session(session)
    |> then(
      &from(t in &1,
        group_by: t.session,
        select: %{session: t.session, turns: count(t.id), last_at: max(t.at)},
        # `at` is second-granularity, so two sessions active in the same second tie -
        # `id` (a microsecond timestamp string) breaks that the same direction, newest last.
        order_by: [desc: max(t.at), desc: max(t.id)],
        limit: ^limit
      )
    )
    |> Repo.all()
    |> Enum.map(fn %{session: s, turns: n, last_at: at} -> %{"session" => s, "turns" => n, "last_at" => at} end)
  end

  @doc """
  Traces in `scope` whose prompt or tool-call/result text contains `query` (case-
  insensitive substring - no full-text index exists, and does not need to at the scale
  one scope's traces stay bounded to, see `@keep`). Newest first, without the full event
  stream (use `get/2` for one trace's complete transcript). `session`, when given,
  restricts this to just that one session key - see `sessions/3` for why that has to
  happen at the query level, not by filtering an already-`limit`-capped result.
  """
  @spec search(String.t(), String.t(), pos_integer(), String.t() | nil) :: [map()]
  def search(scope, query, limit \\ 50, session \\ nil) when is_binary(query) and query != "" do
    needle = String.downcase(query)

    from(t in Trace, where: t.scope == ^scope, order_by: [desc: t.at])
    |> maybe_filter_session(session)
    |> Repo.all()
    |> Enum.filter(&matches?(&1, needle))
    |> Enum.take(limit)
    |> Enum.map(&summarize/1)
  end

  defp maybe_filter_session(query, nil), do: query
  defp maybe_filter_session(query, session), do: from(t in query, where: t.session == ^session)

  defp matches?(%Trace{} = e, needle) do
    haystack =
      [e.prompt | Enum.map(e.events || [], &(&1["args"] || &1["out"] || &1["text"] || ""))]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, needle)
  end

  # --- internals ---------------------------------------------------------------------

  defp to_map(%Trace{} = e) do
    %{
      "id" => e.id,
      "at" => e.at,
      "agent" => e.agent,
      "session" => e.session,
      "source" => e.source,
      "prompt" => e.prompt,
      "ms" => e.ms,
      "outcome" => e.outcome,
      "events" => e.events
    }
  end

  defp summarize(%Trace{} = e) do
    m = to_map(e)
    m |> Map.drop(["events"]) |> Map.put("tools", tool_names(m)) |> Map.put("usage", usage_list(m))
  end

  defp tool_names(%{"events" => events}) when is_list(events) do
    for %{"t" => "tool_call", "name" => n} <- events, do: n
  end

  defp tool_names(_), do: []

  # Compact per-model token usage for the light index (full events dropped from summaries).
  defp usage_list(%{"events" => events}) when is_list(events) do
    for %{"t" => "usage"} = e <- events,
        do: %{"model" => e["model"], "in" => e["in"] || 0, "out" => e["out"] || 0}
  end

  defp usage_list(_), do: []

  defp write(row) do
    Repo.insert_all(Trace, [row])
    trim(row.scope)
    :ok
  end

  # SQLite's `DELETE ... LIMIT` isn't guaranteed compiled into exqlite's bundled build,
  # so this is two statements: how many is this scope over, then delete exactly those
  # (the oldest ones), by id.
  defp trim(scope) do
    count = from(t in Trace, where: t.scope == ^scope) |> Repo.aggregate(:count)

    if count > @keep do
      ids =
        from(t in Trace,
          where: t.scope == ^scope,
          order_by: [asc: t.at, asc: t.id],
          limit: ^(count - @keep),
          select: t.id
        )
        |> Repo.all()

      from(t in Trace, where: t.id in ^ids) |> Repo.delete_all()
    end
  end

  # Microsecond timestamp: unique enough per process, sorts chronologically as a string.
  defp new_id, do: Integer.to_string(System.os_time(:microsecond))

  defp outcome({:ok, _content, _messages}), do: %{"kind" => "ok"}
  # Pepe.Agent.Session's spawn_run/7 success shape: {:ok, content, messages, redaction entries}.
  defp outcome({:ok, _content, _messages, _entries}), do: %{"kind" => "ok"}
  defp outcome({:error, reason}), do: %{"kind" => "error", "reason" => inspect(reason)}
  defp outcome(_), do: %{"kind" => "unknown"}

  # Turn a runtime event into a small JSON-able map, clipping large blobs. Streaming
  # deltas are dropped - the assembled `:assistant` message already carries the text.
  defp encode_event({:assistant, text}), do: %{"t" => "assistant", "text" => clip(text)}
  defp encode_event({:assistant_delta, _}), do: nil
  defp encode_event({:tool_call, name, args}), do: %{"t" => "tool_call", "name" => name, "args" => clip(args)}
  defp encode_event({:tool_result, name, out}), do: %{"t" => "tool_result", "name" => name, "out" => clip(out)}

  defp encode_event({:tool_denied, name, reason}),
    do: %{"t" => "tool_denied", "name" => name, "reason" => reason}

  defp encode_event({:failover, from, to}), do: %{"t" => "failover", "from" => from, "to" => to}

  # The provider had no room left for an answer that big and we asked again for a smaller
  # one (see Pepe.LLM.OutputCap). Worth seeing: a turn that keeps landing here is a turn
  # whose conversation has grown until the answer barely fits.
  defp encode_event({:output_cap, model, cap}),
    do: %{"t" => "output_cap", "model" => model, "cap" => cap}

  # Complexity-routing verdict, recorded before Runtime.run even starts - see
  # Pepe.Agent.Session's spawn_run/7. `chosen_model` is only set on a :simple
  # verdict (the session downgraded); :complex and :failed leave the agent on
  # its own model, so there is nothing to name there.
  defp encode_event({:triage, verdict, triage_model, chosen_model}),
    do: %{"t" => "triage", "verdict" => to_string(verdict), "triage_model" => triage_model, "chosen_model" => chosen_model}

  # A privacy/redaction hook ran (see Pepe.Hooks.transform/4). Never carries the
  # redacted text itself or the reversible map - only that it ran, whether it
  # changed anything, and how many reversible entries it added.
  defp encode_event({:hook, stage, name, changed?, entries_count}),
    do: %{"t" => "hook", "stage" => to_string(stage), "name" => name, "changed" => changed?, "entries" => entries_count}

  defp encode_event({:usage, model, usage}), do: usage_event(model, usage)
  defp encode_event({:error, reason}), do: %{"t" => "error", "reason" => inspect(reason)}
  defp encode_event(_), do: nil

  defp usage_event(model, %{} = usage) do
    usage = Map.new(usage, fn {k, v} -> {to_string(k), v} end)

    %{
      "t" => "usage",
      "model" => model,
      "in" => usage["prompt_tokens"] || usage["input_tokens"],
      "out" => usage["completion_tokens"] || usage["output_tokens"]
    }
  end

  defp usage_event(_, _), do: nil

  defp clip(nil), do: nil

  defp clip(text) when is_binary(text) do
    if byte_size(text) > @clip, do: binary_part(text, 0, @clip) <> " (clipped)", else: text
  end

  defp clip(other), do: clip(inspect(other))

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope) when is_binary(scope), do: scope
end
