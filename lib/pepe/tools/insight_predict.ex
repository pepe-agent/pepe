defmodule Pepe.Tools.InsightPredict do
  @moduledoc """
  Query an already-trained `insight` spec - answer, or inspect what exists - without any of
  `insight`'s own defining/importing/training/deleting power. Split out for the same reason
  `db_query` is split from `manage_db`: an operator who wants a spec's cheap, repeated
  predictions reachable from an unattended surface (a cron job, a webhook) can grant this
  tool - or auto_approve it - without also handing that surface the ability to redefine,
  retrain, or delete the spec it's predicting from.

  Deliberately NOT in `Pepe.Permissions.@always_safe`, same reasoning as `db_query`: still a
  real action against the operator's own trained models, still gated like any other risky
  tool by default, just independently grantable from `insight` itself.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Insight

  @impl true
  def name, do: "insight_predict"

  @impl true
  def spec do
    function(
      "insight_predict",
      """
      Query an already-trained `insight` spec. Read-only: never defines, imports, trains, \
      or deletes anything - use the `insight` tool for that. actions:
      - predict: answer from the current trained model - needs `name`, `input` (object of \
        column -> value; for "forecast", key the time_column to the date/timestamp you \
        want a prediction for). Refuses if nothing has been trained yet - use `insight` \
        train_now first. For a "clustering" spec, answers with which group the input falls \
        into and whether it's an outlier of that group, not a single value.
      - list: show your specs and their status.
      - describe: full detail on one spec plus its model-version history - needs `name`. \
        For "clustering", each trained version also lists what's actually IN each group \
        (size, average feature values) - use this to explain a cluster in plain terms.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(predict list describe), "description" => "What to do."},
          "name" => %{"type" => "string", "description" => "The spec's name."},
          "input" => %{"type" => "object", "description" => "For predict: column -> value."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => "list"}, ctx), do: with_agent(ctx, fn agent -> {:ok, render_list(agent)} end)

  def run(%{"action" => "predict", "name" => name, "input" => input}, ctx) when is_map(input) do
    with_agent(ctx, fn agent -> predict(name, input, agent) end)
  end

  def run(%{"action" => "describe", "name" => name}, ctx) do
    with_agent(ctx, fn agent -> describe(name, agent) end)
  end

  def run(_args, _ctx), do: {:error, "unknown or incomplete action (check the required arguments for it)"}

  defp predict(name, input, agent) do
    case Insight.predict(agent.name, name, input) do
      {:ok, %{"cluster" => cluster} = result} ->
        flag = if result["anomalous"], do: " - ANOMALOUS (far outside this group's usual range)", else: ""
        {:ok, "#{name}: group #{cluster}, distance #{result["distance"]} (z-score #{result["anomaly_score"]})#{flag}"}

      {:ok, value} ->
        {:ok, "#{name} predicts: #{inspect(value)}"}

      {:error, :not_found} ->
        {:error, "no spec named #{name}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp describe(name, agent) do
    case Insight.describe(agent.name, name) do
      nil -> {:error, "no spec named #{name}"}
      spec -> {:ok, render_describe(spec)}
    end
  end

  defp render_list(agent) do
    case Insight.list_specs(agent.name) do
      [] -> "No insight specs defined yet."
      specs -> Enum.map_join(specs, "\n", &spec_line/1)
    end
  end

  defp spec_line(s), do: "• #{s["name"]} (#{s["source_kind"]}, #{s["task_type"]}#{family_suffix(s)}) - #{s["status"]}, #{target_summary(s)}"

  defp family_suffix(%{"family" => f}) when is_binary(f), do: ", #{f} forced"
  defp family_suffix(_s), do: ""

  defp target_summary(%{"task_type" => "clustering"} = s), do: "groups on #{Enum.join(s["feature_columns"], ", ")}"
  defp target_summary(%{"task_type" => "forecast"} = s), do: "forecasts #{s["target_column"]} over #{s["time_column"]}"
  defp target_summary(s), do: "predicts #{s["target_column"]}"

  defp render_describe(spec) do
    header =
      "#{spec["name"]}: #{spec["task_type"]}#{target_line(spec)} from #{Enum.join(spec["feature_columns"], ", ")}\n" <>
        "source: #{spec["source_kind"]}#{if spec["source_kind"] == "db", do: " (#{spec["connection"]}.#{spec["table"]})", else: ""}\n" <>
        "algorithm: #{spec["family"] || "automatic (by data volume)"}\n" <>
        "status: #{spec["status"]}#{if spec["last_error"], do: " (#{spec["last_error"]})", else: ""}"

    models = Map.get(spec, "models", [])
    models_text = if models == [], do: "no trained versions yet", else: Enum.map_join(models, "\n", &model_block/1)

    header <> "\n" <> models_text
  end

  defp target_line(%{"task_type" => "clustering"}), do: ""
  defp target_line(%{"task_type" => "forecast"} = spec), do: " on #{spec["target_column"]} over #{spec["time_column"]}"
  defp target_line(spec), do: " on #{spec["target_column"]}"

  defp model_block(m) do
    line =
      "  v#{m["version"]} (#{m["algorithm"]}): #{m["metric_name"]}=#{Float.round(m["metric_value"] * 1.0, 4)}, #{m["sample_count"]} rows"

    case m["clusters"] do
      groups when is_list(groups) and groups != [] -> line <> "\n" <> Enum.map_join(groups, "\n", &cluster_line/1)
      _ -> line
    end
  end

  defp cluster_line(g) do
    means = Enum.map_join(g["means"], ", ", fn {col, avg} -> "#{col}=#{avg}" end)
    "    group #{g["cluster"]}: #{g["size"]} rows, avg #{means}"
  end

  defp with_agent(ctx, fun) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> fun.(agent)
    end
  end
end
