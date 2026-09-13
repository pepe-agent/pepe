defmodule Pepe.Tools.Insight do
  @moduledoc """
  Define, import data into, and train small local models over data you can already reach -
  a registered database connection (`db_query`'s connections), or rows you fetched some
  other way (e.g. via `bash` + a database CLI for an engine Pepe has no native connector
  for) and hand in directly with `import_rows`. Query an already-trained spec with the
  separate `insight_predict` tool instead.

  Three different jobs, one tool:

    * `"classification"`/`"regression"` - a specific, repeated yes/no or numeric question
      your own data can answer ("will this patient deteriorate", "will this lead convert")
      - not a one-off query (`db_query` already does that). Needs `target_column`.
    * `"clustering"` - no target column at all: groups similar rows together on their own,
      and doubles as anomaly detection (a row far from every group's usual spread comes
      back flagged `"anomalous"` from `insight_predict`).
    * `"forecast"` - predicts `target_column` over time, using `time_column` (a date/
      timestamp column) instead of (or alongside) other feature_columns - "how many next
      week", "what's the trend". `insight_predict` takes a future date, not pre-computed
      features.

  Train once there's enough verified history, then `insight_predict` answers instantly and
  for free instead of reasoning from scratch every call.

  Risky tool: reading an external database (even to train on it) and persisting a model are
  both real actions, gated like `manage_db`. Querying an already-trained spec (`predict`/
  `list`/`describe`) is the separate `insight_predict` tool instead - same split as
  `db_query`/`manage_db` - so an operator can grant cheap, repeated predictions to an
  unattended surface without also granting the power to redefine, retrain, or delete a spec.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Insight
  alias Pepe.Insight.SchemaInspector

  @impl true
  def name, do: "insight"

  @impl true
  def spec do
    function(
      "insight",
      """
      Define, import data into, train, and delete local predictive models over your own \
      data. Use `insight_predict` to query an already-trained spec (predict/list/describe) \
      - this tool never answers a prediction itself. actions:
      - propose_targets: heuristic target-column suggestions for a "db" connection - needs \
        `connection`, optional `table` (every table gets scanned, capped at 10, if \
        omitted). Read-only, defines nothing. A HEURISTIC, NOT A GUARANTEE: always show \
        the candidates to the user and confirm which one (if any) before calling define - \
        never define off a suggestion on your own.
      - define: register what to predict - needs `name`, `source_kind` ("db" or "import"). \
        For "db", also give `connection` (a db_query connection name) and `table`. \
        `target_column` is required for "classification"/"regression"/"forecast", and \
        must be OMITTED for "clustering" (it has no target). `time_column` (a date/\
        timestamp column) is required for "forecast" only. `feature_columns` (array of \
        other column names, numeric only in v1) is required for every task_type except \
        "forecast", where it's optional (a pure time-based forecast needs none). Optional \
        `task_type` ("classification" (default), "regression", "clustering", or \
        "forecast"), `retrain_interval_s` (auto-retrain this often once enough new rows \
        arrive), `min_new_rows` (default 50). Optional `family` ("linear", "gbm", or \
        "neural") forces a specific algorithm instead of Pepe's automatic, data-volume-\
        based choice - leave it out unless the user explicitly asks for a specific one by \
        name; don't offer or suggest it otherwise. Ignored for "clustering" (always \
        k-means).
      - import_rows: for an "import" spec, hand in rows you fetched yourself (e.g. via bash \
        + a database CLI for an engine this Pepe has no native connector for) - needs \
        `name`, `rows` (array of objects, each covering feature_columns, plus \
        target_column/time_column as the spec requires). Optional `replace` (true clears \
        prior rows first).
      - train_now: fit (or refit) the model on everything available so far - needs `name`. \
        Fails clearly if there isn't enough data yet.
      - delete: remove a spec, its models, and any imported rows - needs `name`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(propose_targets define import_rows train_now delete),
            "description" => "What to do."
          },
          "name" => %{"type" => "string", "description" => "The spec's name."},
          "target_column" => %{"type" => "string", "description" => "The column to predict."},
          "time_column" => %{"type" => "string", "description" => "The date/timestamp column (task_type \"forecast\" only)."},
          "feature_columns" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Columns to predict from."},
          "source_kind" => %{"type" => "string", "enum" => ~w(db import)},
          "connection" => %{"type" => "string", "description" => "A db_query connection name (source_kind \"db\")."},
          "table" => %{"type" => "string", "description" => "The table to train from (source_kind \"db\")."},
          "task_type" => %{"type" => "string", "enum" => ~w(classification regression clustering forecast)},
          "family" => %{
            "type" => "string",
            "enum" => ~w(linear gbm neural),
            "description" =>
              "Force a specific algorithm instead of the automatic, data-volume-based choice. Only set this if the user explicitly asks for one by name."
          },
          "retrain_interval_s" => %{"type" => "integer"},
          "min_new_rows" => %{"type" => "integer"},
          "rows" => %{"type" => "array", "items" => %{"type" => "object"}, "description" => "For import_rows."},
          "replace" => %{"type" => "boolean", "description" => "For import_rows: clear prior rows first."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    with_agent(ctx, fn agent -> dispatch(action, args, agent, ctx) end)
  end

  def run(_args, _ctx), do: {:error, "insight needs an `action`"}

  defp dispatch("propose_targets", %{"connection" => connection} = args, _agent, ctx), do: propose_targets(connection, args["table"], ctx)
  defp dispatch("define", args, agent, _ctx), do: define(args, agent)
  defp dispatch("import_rows", %{"name" => name} = args, agent, _ctx), do: import_rows(name, args, agent)
  defp dispatch("train_now", %{"name" => name}, agent, ctx), do: train_now(name, agent, ctx)
  defp dispatch("delete", %{"name" => name}, agent, _ctx), do: delete(name, agent)
  defp dispatch(_other, _args, _agent, _ctx), do: {:error, "unknown or incomplete action (check the required arguments for it)"}

  defp propose_targets(connection, table, ctx) do
    case SchemaInspector.propose(connection, table, ctx) do
      {:ok, []} -> {:ok, "No candidates found - the sampled tables may be too small, or nothing stood out. Try naming a specific `table`."}
      {:ok, candidates} -> {:ok, mark_untrusted(connection, render_candidates(candidates))}
      {:error, reason} -> {:error, Pepe.DB.Query.format_error(reason)}
    end
  end

  # Table/column names here come from the operator's own database, the same class of
  # outside content db_query's own results already are - wrapped the same way before it
  # reaches the model.
  defp mark_untrusted(connection, text), do: Pepe.Security.ExternalContent.mark_untrusted("insight:#{connection}", text)

  defp render_candidates(candidates) do
    lines = candidates |> Enum.with_index(1) |> Enum.map(&candidate_line/1)

    Enum.join(
      lines ++ ["(heuristic, not a guarantee - confirm with the user which one, if any, before calling define)"],
      "\n"
    )
  end

  defp candidate_line({c, i}), do: "#{i}. [#{c.task_type}] #{c.table}.#{c.column} (score #{c.score}): #{c.reason}"

  defp define(args, agent) do
    attrs = %{
      "agent" => agent.name,
      "name" => args["name"],
      "target_column" => args["target_column"],
      "time_column" => args["time_column"],
      "feature_columns" => args["feature_columns"],
      "task_type" => args["task_type"],
      "family" => args["family"],
      "retrain_interval_s" => args["retrain_interval_s"],
      "min_new_rows" => args["min_new_rows"],
      "source" => %{"kind" => args["source_kind"], "connection" => args["connection"], "table" => args["table"]}
    }

    case Insight.define_spec(attrs) do
      {:ok, spec} -> {:ok, "Defined #{spec["name"]} (#{spec["source_kind"]} source#{target_note(spec)})#{family_note(spec)}."}
      {:error, {:invalid, errors}} -> {:error, Enum.join(errors, "; ")}
    end
  end

  defp target_note(%{"task_type" => "clustering"}), do: ", grouping only, no target"
  defp target_note(spec), do: ", predicting #{spec["target_column"]}"

  # Any prior trained model keeps answering under its ORIGINAL family until the next
  # train_now - family isn't part of what forces a spec back to "pending" (see
  # Pepe.Insight.save/2), since setting a preference for next time doesn't invalidate a
  # model that's already working. Silence here would read as "already applied".
  defp family_note(%{"family" => f, "status" => "ready"}) when is_binary(f),
    do: ", family forced to #{f} - takes effect on the next train_now"

  defp family_note(%{"family" => f}) when is_binary(f), do: ", family forced to #{f}"
  defp family_note(_spec), do: ""

  defp import_rows(name, args, agent) do
    rows = args["rows"]
    opts = if args["replace"] == true, do: [replace: true], else: []

    cond do
      not is_list(rows) or rows == [] ->
        {:error, "import_rows needs a non-empty `rows` array"}

      true ->
        case Insight.import_rows(agent.name, name, rows, opts) do
          {:ok, result} ->
            {:ok,
             "Imported #{result["inserted"]} row(s). #{result["total_examples"]} total (needs #{result["min_new_rows"]} new for the next auto-retrain)."}

          {:error, :not_found} ->
            {:error, "no spec named #{name}"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp train_now(name, agent, ctx) do
    case Insight.train_now(agent.name, name, ctx) do
      {:ok, result} ->
        {:ok,
         "Trained #{name} v#{result["version"]} (#{result["algorithm"]}): #{result["metric_name"]} = #{Float.round(result["metric_value"] * 1.0, 4)}."}

      {:error, :not_found} ->
        {:error, "no spec named #{name}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp delete(name, agent) do
    case Insight.delete_spec(agent.name, name) do
      :ok -> {:ok, "Deleted #{name}."}
      {:error, :not_found} -> {:error, "no spec named #{name}"}
    end
  end

  defp with_agent(ctx, fun) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> fun.(agent)
    end
  end
end
