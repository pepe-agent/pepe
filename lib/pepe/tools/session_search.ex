defmodule Pepe.Tools.SessionSearch do
  @moduledoc """
  Find and read past conversations - built entirely on `Pepe.Trace` (already the durable,
  crash-proof record of every run), not a second store: a session's own live process
  (and its crash-recovery mirror, when `persist_sessions` is on) only ever holds the
  *current* conversation and is gone the moment it ends, so traces are the only thing
  that outlives a session and is worth searching.

  Scoped to the calling agent's own project - one project's conversations are not
  another's to read, same boundary every other project-scoped tool already holds. Within
  that, `agent.session_search_scope` decides how far a single call can actually see:
  `"self"` (the default, and the safe one) restricts every action to the calling
  session's own history only; `"project"` (opt-in) restores full project-wide visibility.
  An agent that only ever talks to one operator/team has no one else's conversation to
  leak and can safely widen to `"project"`; an agent serving several different end
  customers under the same project must stay `"self"`, or one customer asking to "search
  my past conversations" could read another's.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config
  alias Pepe.Project
  alias Pepe.Trace

  @impl true
  def name, do: "session_search"

  @impl true
  def spec do
    function(
      "session_search",
      """
      Find and read past conversations (sessions) this project has had, and what happened \
      in them - each one built from the durable trace of every turn, not live memory, so \
      it still works for a session whose own process ended or restarted long ago.

      actions:
      - list_sessions: which conversations have happened, most recently active first, \
        each with its turn count. Optional `limit` (default 50).
      - search: find conversations whose prompt or tool activity mentions `query` \
        (case-insensitive substring). Optional `limit` (default 50).
      - session_history: every turn recorded for one `session` key, oldest first - the \
        conversation's own timeline. Optional `limit` (default 200).
      - show: one turn's full transcript (every tool call, result, and the final reply) \
        by its `trace_id`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(list_sessions search session_history show), "description" => "What to do."},
          "query" => %{"type" => "string", "description" => "Substring to search for, for search."},
          "session" => %{"type" => "string", "description" => "A session key, for session_history (see list_sessions)."},
          "trace_id" => %{"type" => "string", "description" => "One turn's id, for show (see session_history/search)."},
          "limit" => %{"type" => "integer", "description" => "Caps how many results come back."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> dispatch(action, args, scope_of(agent), bound_session(agent, ctx))
    end
  end

  def run(_args, _ctx), do: {:error, "session_search needs an `action`"}

  # A bare/root agent name (no project prefix) has no project slug of its own
  # (Project.of/1 returns nil for it) - traces store it under the actual default
  # project slug instead (see Pepe.Trace's own scope_name/1), so a lookup has to
  # match that, not the raw nil.
  defp scope_of(agent), do: Project.of(agent.name) || Config.default_project_slug()

  # `nil` means "no restriction" (opted into "project"); any other value is the exact
  # session key every action gets locked to. An agent left on the "self" default with no
  # session in ctx at all (a one-shot CLI run, a cron) gets the empty string instead of
  # `nil` - it must never fall through to unrestricted just because there was nothing to
  # restrict TO.
  defp bound_session(%{session_search_scope: "project"}, _ctx), do: nil
  defp bound_session(_agent, ctx), do: ctx[:session_key] || ""

  defp dispatch("list_sessions", args, scope, bound) do
    case Trace.sessions(scope, limit(args), bound) do
      [] -> {:ok, "No conversations recorded yet."}
      sessions -> {:ok, Enum.map_join(sessions, "\n", &describe_session_line/1)}
    end
  end

  defp dispatch("search", args, scope, bound) do
    with {:ok, query} <- require_arg(args, "query") do
      case Trace.search(scope, query, limit(args), bound) do
        [] -> {:ok, "No matches for #{inspect(query)}."}
        traces -> {:ok, Enum.map_join(traces, "\n", &describe_trace_line/1)}
      end
    end
  end

  defp dispatch("session_history", args, scope, bound) do
    with {:ok, session} <- require_arg(args, "session") do
      describe_session_history(scope, session, bound, limit(args, 200))
    end
  end

  defp dispatch("show", args, scope, bound) do
    with {:ok, trace_id} <- require_arg(args, "trace_id") do
      show_trace(scope, trace_id, bound)
    end
  end

  defp dispatch(other, _args, _scope, _bound), do: {:error, "unknown action: #{other}"}

  defp describe_session_history(scope, session, bound, limit) do
    if session_visible?(session, bound) do
      case Trace.for_session(scope, session, limit) do
        [] -> {:ok, "No turns recorded for #{session}."}
        traces -> {:ok, Enum.map_join(traces, "\n", &describe_trace_line/1)}
      end
    else
      # Same message a genuinely-empty session gets - a call scoped to "self" must not
      # distinguish "that session doesn't exist" from "that session isn't yours."
      {:ok, "No turns recorded for #{session}."}
    end
  end

  defp show_trace(scope, trace_id, bound) do
    case Trace.get(scope, trace_id) do
      nil ->
        {:error, "no such trace: #{trace_id}"}

      trace ->
        if session_visible?(trace["session"], bound),
          do: {:ok, describe_transcript(trace)},
          else: {:error, "no such trace: #{trace_id}"}
    end
  end

  defp session_visible?(_session, nil), do: true
  defp session_visible?(session, bound), do: session == bound

  defp limit(args, default \\ 50), do: args["limit"] || default

  defp require_arg(args, key) do
    case args[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "session_search needs `#{key}`"}
    end
  end

  defp describe_session_line(%{"session" => s, "turns" => n, "last_at" => at}),
    do: "#{s}  (#{n} turn#{if n == 1, do: "", else: "s"}, last #{fmt_time(at)})"

  defp describe_trace_line(t) do
    kind = get_in(t, ["outcome", "kind"]) || "?"
    tools = Enum.join(t["tools"] || [], ", ")
    prompt = clip(t["prompt"])

    "#{t["id"]}  #{fmt_time(t["at"])}  #{t["agent"]}  #{kind}#{if tools != "", do: "  [#{tools}]", else: ""}#{if prompt != "", do: "  · #{prompt}", else: ""}"
  end

  defp clip(nil), do: ""
  defp clip(text) when byte_size(text) <= 80, do: text
  defp clip(text), do: binary_part(text, 0, 80) <> "…"

  defp describe_transcript(t) do
    header = "#{t["agent"]}  session=#{t["session"] || "-"}  #{get_in(t, ["outcome", "kind"])}\n\nprompt: #{t["prompt"]}\n"
    events = (t["events"] || []) |> Enum.map(&describe_event/1) |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    header <> "\n" <> events
  end

  defp describe_event(%{"t" => "tool_call", "name" => name, "args" => args}), do: "-> #{name} #{args}"
  defp describe_event(%{"t" => "tool_result", "out" => out}), do: "   #{out}"
  defp describe_event(%{"t" => "tool_denied", "name" => name}), do: "x #{name} (denied)"
  defp describe_event(%{"t" => "assistant", "text" => text}), do: "• #{text}"
  defp describe_event(_ev), do: nil

  defp fmt_time(nil), do: "-"

  defp fmt_time(unix) when is_integer(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M")
  end
end
