defmodule Pepe.Usage.Runs do
  @moduledoc """
  One durable row per **run** - one inbound message, and everything the agent did to
  answer it.

  A single message can cost several model calls: the agent answers, calls a tool, is fed
  the result, calls another, and answers again. The ledger (`Pepe.Usage.Log`) records each
  of those calls separately, which is right for money but loses the shape of the turn. This
  table restores it: one row per run, carrying which tools ran, how long it took and how it
  ended, keyed by the same `run_id` the ledger's rows now carry.

  **No money lives here.** What a run cost is always derived from the ledger's entries for
  that `run_id`, so the two can never drift into disagreeing about a number a client is
  billed for. This table answers "what did it do", never "what does it cost".

  It is also not `Pepe.Trace`, which records the same runs with their full transcript
  (prompt, tool arguments, tool output) and is trimmed per scope to stay bounded. Traces are
  diagnostic and expire; these rows are part of the billing record and are kept, which is
  exactly why they hold no conversation content.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Usage.Run

  @doc """
  Record one finished run. `row` is the trace row `Pepe.Trace.finish/1` assembled, from
  which only the non-content fields are kept. A row with no id is ignored.
  """
  @spec record(map()) :: :ok
  def record(%{id: id, scope: scope, at: at} = row) when is_binary(id) do
    Repo.insert_all(
      Run,
      [
        %{
          id: id,
          project: scope_name(scope),
          at: at,
          agent: row[:agent],
          session: row[:session],
          source: row[:source],
          ms: row[:ms],
          outcome: outcome_kind(row[:outcome]),
          tools: tool_names(row[:events])
        }
      ],
      on_conflict: :nothing
    )

    :ok
  end

  def record(_row), do: :ok

  @doc """
  Runs for a scope, newest first. `scope` is `:all`, a list of project slugs, or one
  scope name (`nil`/`""` meaning the default project).

  Options: `:agent`, `:source`, `:session` (exact matches), `:from`/`:to` (unix seconds,
  `[from, to)`), `:cursor` (a run id - only runs before it) and `:limit` (default 100).

  Paging runs on the id rather than on `at`, for the reason `Pepe.Usage.Log.recent/2`
  spells out: `at` is second-granularity and a page boundary inside a busy second would
  either lose rows or repeat them. A run id is a microsecond timestamp of fixed width, so
  ordering it as a string is ordering it in time.
  """
  @spec list(:all | [String.t()] | String.t() | nil, keyword()) :: [map()]
  def list(scope, opts \\ []) do
    Run
    |> scope_query(scope)
    |> filter(:agent, opts[:agent])
    |> filter(:source, opts[:source])
    |> filter(:session, opts[:session])
    |> from_filter(opts[:from])
    |> to_filter(opts[:to])
    |> cursor(opts[:cursor])
    |> then(&from(r in &1, order_by: [desc: r.id], limit: ^(opts[:limit] || 100)))
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc "One run by id, within `scope`, or `nil`. `scope` may be `:all`."
  @spec get(:all | [String.t()] | String.t() | nil, String.t()) :: map() | nil
  def get(scope, id) when is_binary(id) do
    Run
    |> scope_query(scope)
    |> then(&from(r in &1, where: r.id == ^id, limit: 1))
    |> Repo.one()
    |> case do
      nil -> nil
      run -> to_map(run)
    end
  end

  @doc """
  Re-point every run recorded under `old` (a project slug) to `new` - called on a project
  rename, for the same reason `Pepe.Usage.Log.rescope_project/2` is.
  """
  @spec rescope_project(String.t(), String.t()) :: :ok
  def rescope_project(old, new) do
    from(r in Run, where: r.project == ^old) |> Repo.update_all(set: [project: new])
    :ok
  end

  defp scope_query(query, :all), do: query
  defp scope_query(query, list) when is_list(list), do: from(r in query, where: r.project in ^list)

  defp scope_query(query, scope) do
    name = scope_name(scope)
    from(r in query, where: r.project == ^name)
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, :agent, value), do: from(r in query, where: r.agent == ^value)
  defp filter(query, :source, value), do: from(r in query, where: r.source == ^value)
  defp filter(query, :session, value), do: from(r in query, where: r.session == ^value)

  defp from_filter(query, nil), do: query
  defp from_filter(query, at), do: from(r in query, where: r.at >= ^at)

  defp to_filter(query, nil), do: query
  defp to_filter(query, at), do: from(r in query, where: r.at < ^at)

  defp cursor(query, nil), do: query
  defp cursor(query, id), do: from(r in query, where: r.id < ^id)

  defp to_map(%Run{} = r) do
    tools = r.tools || []

    %{
      "id" => r.id,
      "project" => r.project,
      "at" => r.at,
      "agent" => r.agent,
      "session" => r.session,
      "source" => r.source,
      "ms" => r.ms,
      "outcome" => r.outcome,
      "tools" => tools,
      "tool_calls" => length(tools)
    }
  end

  # Only the outcome's kind ("ok"/"error"/"unknown"), never the failure reason: an error
  # reason is an inspected term that can carry a provider's base_url and other internals,
  # and these rows are readable by a client's usage token.
  defp outcome_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp outcome_kind(_), do: nil

  defp tool_names(events) when is_list(events) do
    for %{"t" => "tool_call", "name" => name} <- events, do: name
  end

  defp tool_names(_), do: []

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope), do: to_string(scope)
end
