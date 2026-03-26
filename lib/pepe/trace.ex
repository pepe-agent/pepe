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

  Traces are capped per scope (the oldest are trimmed) so the directory stays bounded.
  They are diagnostic, not a billing record - that is `Pepe.Usage.Log`.
  """

  alias Pepe.Company
  alias Pepe.Config

  @key :pepe_trace
  @keep 200
  @clip 4_000

  @doc "Root directory holding the per-scope trace files."
  def dir, do: Path.join([Config.home(), "data", "traces"])

  @doc "The directory for one scope (`nil`/`\"root\"` -> `root/`)."
  def scope_dir(scope), do: Path.join(dir(), scope_name(scope))

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
          scope: Company.of(agent_name),
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

  @doc "Append one runtime lifecycle event to the in-progress trace (no-op if none)."
  def event(ev) do
    case {Process.get(@key), encode_event(ev)} do
      {nil, _} -> :ok
      {_, nil} -> :ok
      {t, e} -> Process.put(@key, %{t | events: [e | t.events]})
    end

    :ok
  end

  @doc "Write the accumulated trace for this process to disk and clear it. Returns the id."
  def finish(result) do
    case Process.get(@key) do
      nil ->
        :ok

      t ->
        Process.delete(@key)

        entry = %{
          "id" => t.id,
          "at" => t.at,
          "agent" => t.agent,
          "session" => t.session,
          "source" => t.source,
          "prompt" => t.prompt,
          "ms" => System.monotonic_time(:millisecond) - t.t0,
          "outcome" => outcome(result),
          "events" => Enum.reverse(t.events)
        }

        write(t.scope, entry)
        t.id
    end
  rescue
    _ -> :ok
  end

  # --- reading (dashboard / CLI) -----------------------------------------------------

  @doc "Scopes (companies + root) that have any recorded trace."
  def scopes do
    case File.ls(dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  @doc """
  Recent traces for a scope, newest first, without their event stream (a light list for
  the index). `limit` caps how many are returned.
  """
  def recent(scope, limit \\ 50) do
    scope
    |> files()
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.map(&read_summary(scope, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Load one full trace (with its events) by id, or `nil` if it is gone."
  def get(scope, id) do
    with {:ok, body} <- File.read(Path.join(scope_dir(scope), "#{id}.json")),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> nil
    end
  end

  # --- internals ---------------------------------------------------------------------

  defp files(scope) do
    case File.ls(scope_dir(scope)) do
      {:ok, names} ->
        names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()

      _ ->
        []
    end
  end

  defp read_summary(scope, file) do
    case File.read(Path.join(scope_dir(scope), file)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} -> Map.drop(m, ["events"]) |> Map.put("tools", tool_names(m)) |> Map.put("usage", usage_list(m))
          _ -> nil
        end

      _ ->
        nil
    end
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

  defp write(scope, entry) do
    d = scope_dir(scope)
    File.mkdir_p!(d)
    File.write!(Path.join(d, "#{entry["id"]}.json"), Jason.encode!(entry))
    trim(scope)
    :ok
  end

  defp trim(scope) do
    kept = files(scope)

    if length(kept) > @keep do
      d = scope_dir(scope)

      kept
      |> Enum.take(length(kept) - @keep)
      |> Enum.each(fn f -> File.rm(Path.join(d, f)) end)
    end
  end

  # Microsecond timestamp: unique enough per process, sorts chronologically as a string.
  defp new_id, do: Integer.to_string(System.os_time(:microsecond))

  defp outcome({:ok, _content, _messages}), do: %{"kind" => "ok"}
  defp outcome({:error, reason}), do: %{"kind" => "error", "reason" => inspect(reason)}
  defp outcome(_), do: %{"kind" => "unknown"}

  # Turn a runtime event into a small JSON-able map, clipping large blobs. Streaming
  # deltas are dropped - the assembled `:assistant` message already carries the text.
  defp encode_event({:assistant, text}), do: %{"t" => "assistant", "text" => clip(text)}
  defp encode_event({:assistant_delta, _}), do: nil
  defp encode_event({:tool_call, name, args}), do: %{"t" => "tool_call", "name" => name, "args" => clip(args)}
  defp encode_event({:tool_result, name, out}), do: %{"t" => "tool_result", "name" => name, "out" => clip(out)}
  defp encode_event({:tool_denied, name}), do: %{"t" => "tool_denied", "name" => name}
  defp encode_event({:failover, from, to}), do: %{"t" => "failover", "from" => from, "to" => to}
  defp encode_event({:usage, model, usage}), do: usage_event(model, usage)
  defp encode_event({:error, reason}), do: %{"t" => "error", "reason" => inspect(reason)}
  defp encode_event(_), do: nil

  defp usage_event(model, %{} = usage) do
    %{
      "t" => "usage",
      "model" => model,
      "in" => usage[:prompt_tokens] || usage["prompt_tokens"] || usage[:input_tokens] || usage["input_tokens"],
      "out" => usage[:completion_tokens] || usage["completion_tokens"] || usage[:output_tokens] || usage["output_tokens"]
    }
  end

  defp usage_event(_, _), do: nil

  defp clip(nil), do: nil

  defp clip(text) when is_binary(text) do
    if byte_size(text) > @clip, do: binary_part(text, 0, @clip) <> " (clipped)", else: text
  end

  defp clip(other), do: clip(inspect(other))

  defp scope_name(nil), do: "root"
  defp scope_name("root"), do: "root"
  defp scope_name(scope) when is_binary(scope), do: scope
end
