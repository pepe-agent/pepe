defmodule Pepe.Insight.Predictor do
  @moduledoc """
  Pure local inference from an already-trained `Pepe.Insight.Model` - no DB/connection
  involved at all, unlike `Trainer`/`Source`. Deserializes the stored artifact and runs the
  matching algorithm's `predict` - `Scholar.Linear.*` directly for the small-data tier,
  `EXGBoost.predict/2` (its own native model format, not `Nx.serialize`) for the mid-size
  tier, or `Pepe.Insight.Neural`'s architecture rebuilt from the model's own recorded
  dimensions (`params["input_width"]`, `params["classes"]` count) for the large-data tier -
  Axon models are graph + weights, and only the weights (`Axon.ModelState`) get serialized
  via `Nx.serialize/1`; the graph is cheap and deterministic to rebuild from the same two
  numbers every time. `input_width` is the *encoded* tensor width, not
  `length(feature_columns)`: a one-hot categorical column (see `Pepe.Insight.Categorical`)
  contributes more than one dimension per feature column, so the two can differ. A model
  trained before `input_width` existed has none stored - `length(feature_columns)` is still
  correct for that older model (it predates categorical features entirely), so it's the
  fallback, not a hard requirement.

  A feature column's raw value is turned into one or more tensor dimensions by
  `Pepe.Insight.Categorical.feature_vector/3` - the same function `Trainer` uses to encode
  rows at training time, given the same `feature_columns` and the same `params["categories"]`
  vocabulary this model was trained with, so the two can never encode a value differently.

  A `"kmeans"` model answers a different shape of question - not a single value, but which
  cluster a new point falls into and how far it sits from that cluster's usual spread
  (`params["distance_mean"]`/`params["distance_stddev"]`, from `Trainer.fit_clustering/2`),
  turned into a z-score: past roughly 3 standard deviations is flagged anomalous, the same
  everyday threshold a statistics-based outlier check would use.

  A `"forecast"` spec's model is an ordinary regression algorithm underneath
  (`model.algorithm` is `"linear_regression"`/`"gbm_regressor"`/`"neural_regressor"`, never
  a distinct name), so once the input row is built there is nothing forecast-specific left
  to do - `run_predict/3` handles it exactly like any other regression. The only special
  step is building that row: the caller supplies a raw timestamp under `params["time_column"]`
  instead of pre-computed features, which `Pepe.Insight.TimeFeatures.features/2` turns into
  the same 5 numbers `Trainer.fit_forecast/3` derived at training time, using the same
  `params["epoch"]` reference point so the two never drift apart.
  """

  alias Pepe.Insight.Categorical
  alias Pepe.Insight.Model
  alias Pepe.Insight.Neural
  alias Pepe.Insight.Scaling
  alias Pepe.Insight.TimeFeatures

  @spec predict(Model.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def predict(%Model{task_type: "forecast"} = model, input) when is_map(input) do
    with {:ok, values} <- forecast_feature_row(model, input) do
      artifact = deserialize(model.algorithm, model.artifact)
      tensor = values |> build_tensor() |> scale_tensor(model)
      {:ok, run_predict(model, artifact, tensor)}
    end
  end

  def predict(%Model{} = model, input) when is_map(input) do
    with {:ok, values} <- feature_row(model.feature_columns, input, categories(model)) do
      artifact = deserialize(model.algorithm, model.artifact)
      tensor = values |> build_tensor() |> scale_tensor(model)
      {:ok, run_predict(model, artifact, tensor)}
    end
  end

  defp categories(%Model{params: params}), do: params["categories"] || %{}

  defp build_tensor(values), do: Nx.tensor([values], type: :f32)

  # The same standardization Trainer fit on the training split, reapplied here so a new
  # row lands in the exact space the model was fit in. Falls back to leaving the tensor
  # untouched for a model trained before this existed (no "scale" in its params) rather
  # than crashing an otherwise-still-valid older model.
  defp scale_tensor(tensor, %Model{params: %{"scale" => %{"mean" => _, "stddev" => _} = scale}}) do
    Scaling.apply(tensor, Scaling.from_params(scale))
  end

  defp scale_tensor(tensor, _model), do: tensor

  defp forecast_feature_row(model, input) do
    time_column = model.params["time_column"]
    real_columns = model.params["real_feature_columns"] || []

    with {:ok, epoch} <- parse_epoch(model.params["epoch"]),
         {:ok, dt} <- fetch_time(input, time_column),
         {:ok, extra} <- feature_row(real_columns, input, categories(model)) do
      {:ok, TimeFeatures.features(dt, epoch) ++ extra}
    end
  end

  defp fetch_time(input, time_column) do
    case TimeFeatures.parse(Map.get(input, time_column)) do
      {:ok, dt} -> {:ok, dt}
      :error -> {:error, "missing or unparseable value for time column #{inspect(time_column)}"}
    end
  end

  # TimeFeatures.parse/1 returns a bare :error, not {:error, _} - left unwrapped here it
  # would make this `with` return a bare :error too (no `else` clause to catch it), which
  # violates predict/2's own {:ok, _} | {:error, _} contract and crashes the tool's own
  # `case` on the result instead of surfacing a clean message.
  defp parse_epoch(epoch) do
    case TimeFeatures.parse(epoch) do
      {:ok, dt} -> {:ok, dt}
      :error -> {:error, "this model's stored training reference point is corrupted - retrain it with train_now"}
    end
  end

  # See Pepe.Insight.serialize_artifact/2 (the write side of this same split).
  defp deserialize(alg, binary) when alg in ["gbm_classifier", "gbm_regressor"], do: EXGBoost.load_model(binary)
  defp deserialize(_alg, binary), do: Nx.deserialize(binary)

  defp run_predict(%Model{algorithm: "logistic_regression"} = model, artifact, tensor) do
    [idx] = artifact |> Scholar.Linear.LogisticRegression.predict(tensor) |> Nx.to_flat_list()
    decode_class(model, idx)
  end

  defp run_predict(%Model{algorithm: "linear_regression"}, artifact, tensor) do
    [value] = artifact |> Scholar.Linear.LinearRegression.predict(tensor) |> Nx.to_flat_list()
    value
  end

  defp run_predict(%Model{algorithm: "neural_classifier"} = model, artifact, tensor) do
    classes = model.params["classes"] || []
    graph = Neural.build(input_width(model), length(classes))
    [idx] = graph |> Neural.predict(artifact, tensor) |> Nx.argmax(axis: -1) |> Nx.to_flat_list()
    decode_class(model, idx)
  end

  defp run_predict(%Model{algorithm: "neural_regressor"} = model, artifact, tensor) do
    graph = Neural.build(input_width(model), 1)
    [value] = graph |> Neural.predict(artifact, tensor) |> Nx.to_flat_list()
    value
  end

  defp run_predict(%Model{algorithm: "gbm_classifier"} = model, artifact, tensor) do
    [idx] = artifact |> EXGBoost.predict(tensor) |> Nx.round() |> Nx.as_type({:s, 64}) |> Nx.to_flat_list()
    decode_class(model, idx)
  end

  defp run_predict(%Model{algorithm: "gbm_regressor"}, artifact, tensor) do
    [value] = artifact |> EXGBoost.predict(tensor) |> Nx.to_flat_list()
    value
  end

  defp run_predict(%Model{algorithm: "kmeans"} = model, artifact, tensor) do
    [cluster] = artifact |> Scholar.Cluster.KMeans.predict(tensor) |> Nx.to_flat_list()
    centroid = Nx.slice_along_axis(artifact.clusters, cluster, 1, axis: 0)
    distance = Scholar.Metrics.Distance.euclidean(tensor, centroid) |> Nx.to_number()

    mean_d = model.params["distance_mean"] || 0.0
    stddev_d = model.params["distance_stddev"] || 0.0
    z = if stddev_d > 0, do: (distance - mean_d) / stddev_d, else: 0.0

    %{
      "cluster" => cluster,
      "distance" => Float.round(distance * 1.0, 4),
      "anomaly_score" => Float.round(z * 1.0, 4),
      "anomalous" => z > 3.0
    }
  end

  defp input_width(%Model{params: %{"input_width" => width}}), do: width
  defp input_width(%Model{feature_columns: cols}), do: length(cols)

  defp decode_class(model, idx) do
    classes = model.params["classes"] || []
    Enum.at(classes, idx, idx)
  end

  defp feature_row(feature_columns, input, categories), do: Categorical.feature_vector(input, feature_columns, categories)
end
