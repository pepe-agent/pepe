defmodule Pepe.Insight.Trainer do
  @moduledoc """
  Fetches rows (via `Pepe.Insight.Source`, regardless of `source_kind`) and fits one
  algorithm, picked automatically by default - "Pepe decides", never a required user
  choice. `spec.family` is the one deliberate exception: an operator who already knows
  which family they want (`"linear"`, `"gbm"`, or `"neural"`) can set it explicitly and
  `family_for/2` honors it outright, skipping the volume-based heuristic below entirely -
  automatic is the default *because* nobody has to think about this, not because the
  choice is hidden from whoever wants to make it themselves.

  For `"classification"`/`"regression"` specs left on automatic, the algorithm is picked by
  how much data actually exists, three tiers:

    * fewer than `@small_data_threshold` rows -> `Scholar.Linear.LogisticRegression`/
      `LinearRegression` - too little data for gradient-boosted trees to avoid overfitting;
      a small operator with a few hundred rows and no ML team gets a model that just works,
      instantly.
    * `@small_data_threshold` to `@large_data_threshold` rows -> `Pepe.Insight.GBMTrainer`
      (gradient-boosted trees via `EXGBoost`/XGBoost) - the default workhorse tier and the
      strongest general baseline for tabular business data at the scale most real operators
      actually have.
    * `@large_data_threshold` rows or more -> `Pepe.Insight.NeuralTrainer`'s fixed neural
      net - reserved for the very largest operators (hundreds of millions of rows); gradient
      boosting is usually competitive here too, but this tier exists for whoever has more
      data than GBM can fully exploit.

  Scored on a holdout split, never the training rows: scoring on the training rows would
  always overstate accuracy, and the whole "gets more accurate as more data accumulates"
  premise this feature exists to deliver depends on that number being honest.

  Every feature column is standardized (`Pepe.Insight.Scaling`, zero mean/unit variance)
  before any of the above sees it, fit once from the training split and reused unchanged
  for holdout scoring and every later `predict`. Without this, a raw column's native units
  (age in the 0-100s next to revenue in the millions) silently dominate both k-means
  distance and logistic regression's gradient descent - "nothing to tune" has to include
  not needing to know this exists, not just not being asked to set it.

  For `"clustering"` specs (no target column - there's nothing to hold out or predict),
  `Scholar.Cluster.KMeans` fits every candidate cluster count from 2 to `@max_clusters` and
  keeps whichever scores best on `Scholar.Metrics.Clustering.silhouette_score/3` - picking
  `k` on the fit data is the standard way to choose it for k-means, unlike a supervised
  accuracy number, so this does not need a holdout split to stay honest. The same fitted
  model also answers "how anomalous is this point": each training point's distance to its
  own cluster's centroid becomes a mean/stddev baseline (`Predictor` turns a new point's
  distance into a z-score against that baseline) - one model serves both capabilities
  instead of training two. Silhouette scoring is O(n^2), so clustering fits on at most
  `@clustering_max_rows` rows, a random subsample when the source hands back more.

  For `"forecast"` specs (a `target_column` plus a `time_column`, no target/time leakage
  concern beyond the usual holdout split), `Pepe.Insight.TimeFeatures` turns each row's
  timestamp into 5 numeric features (elapsed time since the training set's earliest
  timestamp, plus cyclical day-of-week/month encodings) prepended to any real
  `feature_columns`, and the result is fit through the exact same three-tier family
  selection as `"regression"` - a forecast is just a regression whose features happen to be
  derived from a clock instead of typed in. `fit_forecast/3` reuses `fit_and_score/5`
  directly (passing it a spec relabeled `"regression"` for that one call) rather than
  duplicating the tier-selection logic.

  Everything from `encode/3`/`feature_matrix/2` down takes plain Elixir rows and needs no
  live connection, so it's unit-testable with fixtures; only `Source.fetch/3`'s `"db"`
  branch needs a real Postgres to exercise (same gap `test/pepe/tools/db_query_test.exs`
  already documents and defers to manual verification).
  """

  alias Pepe.Insight.GBMTrainer
  alias Pepe.Insight.Neural
  alias Pepe.Insight.NeuralTrainer
  alias Pepe.Insight.Numeric
  alias Pepe.Insight.Scaling
  alias Pepe.Insight.Source
  alias Pepe.Insight.Spec
  alias Pepe.Insight.TimeFeatures

  @min_rows 20
  @small_data_threshold 2_000
  @large_data_threshold 50_000
  @max_clusters 8
  # A single row with a missing/non-numeric value in a checked column used to abort the
  # entire fit - real production tables have occasional NULLs, and one bad row out of
  # hundreds of thousands shouldn't sink the whole training run. Rows are dropped instead,
  # up to this fraction of the batch; past it, something is wrong enough (wrong column,
  # wrong table) that failing loudly beats silently training on a small remainder.
  @max_dropped_ratio 0.10
  # Silhouette scoring is O(n^2) in memory and time (a full pairwise-distance matrix per
  # candidate k) - uncapped, a "db" spec's 200,000-row sample would try to allocate a
  # multi-gigabyte f32 matrix per k. A random subsample keeps clustering usable at any
  # underlying data size instead of OOMing or hanging on real-sized tables.
  @clustering_max_rows 1_500

  @spec train(Spec.t(), map()) :: {:ok, map()} | {:error, term()}
  def train(%Spec{task_type: "clustering"} = spec, ctx) do
    with {:ok, population} <- Source.row_count(spec, ctx),
         {:ok, rows} <- Source.fetch(spec, ctx, population),
         {:ok, clean_rows, _dropped} <- drop_incomplete_rows(rows, spec.feature_columns),
         :ok <- check_row_count(clean_rows) do
      fit_clustering(spec, clean_rows, population)
    end
  end

  def train(%Spec{task_type: "forecast"} = spec, ctx) do
    with {:ok, population} <- Source.row_count(spec, ctx),
         {:ok, rows} <- Source.fetch(spec, ctx, population),
         {:ok, clean_rows, _dropped} <- drop_incomplete_rows(rows, [spec.target_column | spec.feature_columns]),
         :ok <- check_row_count(clean_rows) do
      fit_forecast(spec, clean_rows, population)
    end
  end

  def train(%Spec{} = spec, ctx) do
    numeric_columns = if spec.task_type == "regression", do: [spec.target_column | spec.feature_columns], else: spec.feature_columns

    with {:ok, population} <- Source.row_count(spec, ctx),
         {:ok, fetched} <- Source.fetch(spec, ctx, population),
         {:ok, rows, _dropped} <- drop_incomplete_rows(fetched, numeric_columns),
         :ok <- check_row_count(rows),
         # Classes are resolved from every fetched row, before the split - not from the
         # train partition alone. A rare class can land entirely in the holdout by chance,
         # and deriving classes from train_rows only would then reject a genuinely valid
         # 2-class dataset just because of how the shuffle happened to fall.
         {:ok, classes} <- resolve_classes(rows, spec) do
      family = family_for(population, spec.family)
      {train_rows, holdout_rows} = split(rows)

      with {:ok, encoded} <- encode(train_rows, spec, classes),
           {:ok, holdout} <- encode(holdout_rows, spec, classes) do
        # Fit the scale on the training split only, never the holdout - fitting on both
        # would leak holdout distribution info into what's supposed to be an honest score.
        scale = Scaling.fit(encoded.x)
        scaled_train = %{encoded | x: Scaling.apply(encoded.x, scale)}
        scaled_holdout = %{holdout | x: Scaling.apply(holdout.x, scale)}
        {:ok, result} = fit_and_score(spec, family, scaled_train, scaled_holdout, length(rows))
        {:ok, result |> with_scale(scale) |> Map.put(:population, population)}
      end
    end
  end

  # A missing/non-numeric value in a checked column drops just that row instead of aborting
  # the whole fit - up to @max_dropped_ratio of the batch, past which something is wrong
  # enough (bad column, bad table) that failing loudly beats training on a small remainder.
  defp drop_incomplete_rows(rows, numeric_columns) do
    total = length(rows)
    clean = Enum.filter(rows, &Enum.all?(numeric_columns, fn col -> numeric?(Map.get(&1, col)) end))
    dropped = total - length(clean)

    if total > 0 and dropped / total > @max_dropped_ratio do
      {:error, "too many rows (#{dropped}/#{total}) have a missing or non-numeric value in #{inspect(numeric_columns)}"}
    else
      {:ok, clean, dropped}
    end
  end

  defp numeric?(value), do: match?({:ok, _}, Numeric.to_number(value))

  # Every fit_and_score/5 result gets the same training-time scale attached, regardless of
  # algorithm - Predictor applies it to a new row before calling any of them, so a raw
  # column (age in the 0-100s, revenue in the millions) never silently dominates a distance
  # or gradient computation just because of its native units.
  defp with_scale(result, scale) do
    extra = Map.put(Map.get(result, :extra_params, %{}), "scale", Scaling.to_params(scale))
    Map.put(result, :extra_params, extra)
  end

  defp resolve_classes(rows, %Spec{task_type: "classification", target_column: col}) do
    classes = rows |> Enum.map(&to_label(Map.get(&1, col))) |> Enum.uniq() |> Enum.sort()

    case classes do
      [_, _ | _] -> {:ok, classes}
      _ -> {:error, "target column #{inspect(col)} needs at least 2 distinct classes to train a classifier"}
    end
  end

  defp resolve_classes(_rows, _spec), do: {:ok, nil}

  # An explicit spec.family override (an operator who knows exactly which family they want)
  # always wins over the automatic, volume-based choice - nil (the default) is what leaves
  # Pepe to decide.
  defp family_for(_population, "linear"), do: :linear
  defp family_for(_population, "gbm"), do: :gbm
  defp family_for(_population, "neural"), do: :neural
  defp family_for(population, _override), do: auto_family_for(population)

  defp auto_family_for(population) when population >= @large_data_threshold, do: :neural
  defp auto_family_for(population) when population >= @small_data_threshold, do: :gbm
  defp auto_family_for(_population), do: :linear

  defp check_row_count(rows) do
    if length(rows) >= @min_rows,
      do: :ok,
      else: {:error, "needs at least #{@min_rows} example rows to train (found #{length(rows)})"}
  end

  defp split(rows) do
    shuffled = Enum.shuffle(rows)
    holdout_n = max(1, div(length(shuffled), 5))
    {holdout, train} = Enum.split(shuffled, holdout_n)
    {train, holdout}
  end

  @doc false
  @spec encode([map()], Spec.t(), [String.t()] | nil) :: {:ok, map()} | {:error, String.t()}
  def encode(rows, %Spec{} = spec, classes) do
    with {:ok, x} <- feature_matrix(rows, spec.feature_columns),
         {:ok, y, out_classes} <- target_vector(rows, spec, classes) do
      {:ok, %{x: Nx.tensor(x, type: :f32), y: y, classes: out_classes}}
    end
  end

  defp feature_matrix(rows, feature_columns) do
    try_map(rows, fn row -> try_map(feature_columns, fn col -> numeric_or_error(row, col, "feature") end) end)
  end

  defp target_vector(rows, %Spec{task_type: "regression", target_column: col}, _classes) do
    case try_map(rows, fn row -> numeric_or_error(row, col, "target") end) do
      {:ok, values} -> {:ok, Nx.tensor(values, type: :f32), nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_vector(rows, %Spec{task_type: "classification", target_column: col}, nil) do
    labels = Enum.map(rows, &to_label(Map.get(&1, col)))
    classes = labels |> Enum.uniq() |> Enum.sort()

    case classes do
      [_, _ | _] ->
        index = classes |> Enum.with_index() |> Map.new()
        {:ok, Nx.tensor(Enum.map(labels, &Map.fetch!(index, &1)), type: {:s, 64}), classes}

      _ ->
        {:error, "target column #{inspect(col)} needs at least 2 distinct classes to train a classifier"}
    end
  end

  defp target_vector(rows, %Spec{task_type: "classification", target_column: col}, classes) do
    index = classes |> Enum.with_index() |> Map.new()
    labels = Enum.map(rows, &to_label(Map.get(&1, col)))
    {:ok, Nx.tensor(Enum.map(labels, &Map.get(index, &1, -1)), type: {:s, 64}), classes}
  end

  defp to_label(nil), do: ""
  defp to_label(v) when is_binary(v), do: v
  defp to_label(%Decimal{} = d), do: Decimal.to_string(d)
  defp to_label(v), do: to_string(v)

  defp fit_and_score(%Spec{task_type: "classification"}, :linear, encoded, holdout, total_n) do
    num_classes = length(encoded.classes)
    model = Scholar.Linear.LogisticRegression.fit(encoded.x, encoded.y, num_classes: num_classes)
    preds = Scholar.Linear.LogisticRegression.predict(model, holdout.x)
    metric = holdout.y |> Scholar.Metrics.Classification.accuracy(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "logistic_regression",
       task_type: "classification",
       metric_name: "accuracy",
       metric_value: metric,
       model: model,
       classes: encoded.classes,
       sample_count: total_n
     }}
  end

  defp fit_and_score(%Spec{task_type: "regression"}, :linear, encoded, holdout, total_n) do
    model = Scholar.Linear.LinearRegression.fit(encoded.x, encoded.y)
    preds = Scholar.Linear.LinearRegression.predict(model, holdout.x)
    mse = holdout.y |> Scholar.Metrics.Regression.mean_square_error(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "linear_regression",
       task_type: "regression",
       metric_name: "rmse",
       metric_value: :math.sqrt(max(mse, 0.0)),
       model: model,
       classes: nil,
       sample_count: total_n
     }}
  end

  defp fit_and_score(%Spec{task_type: "classification"}, :gbm, encoded, holdout, total_n) do
    num_classes = length(encoded.classes)
    model = GBMTrainer.fit_classifier(encoded.x, encoded.y, num_classes)
    preds = EXGBoost.predict(model, holdout.x)
    metric = holdout.y |> Scholar.Metrics.Classification.accuracy(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "gbm_classifier",
       task_type: "classification",
       metric_name: "accuracy",
       metric_value: metric,
       model: model,
       classes: encoded.classes,
       sample_count: total_n
     }}
  end

  defp fit_and_score(%Spec{task_type: "regression"}, :gbm, encoded, holdout, total_n) do
    model = GBMTrainer.fit_regressor(encoded.x, encoded.y)
    preds = EXGBoost.predict(model, holdout.x)
    mse = holdout.y |> Scholar.Metrics.Regression.mean_square_error(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "gbm_regressor",
       task_type: "regression",
       metric_name: "rmse",
       metric_value: :math.sqrt(max(mse, 0.0)),
       model: model,
       classes: nil,
       sample_count: total_n
     }}
  end

  defp fit_and_score(%Spec{task_type: "classification"}, :neural, encoded, holdout, total_n) do
    num_classes = length(encoded.classes)
    model_state = NeuralTrainer.fit_classifier(encoded.x, encoded.y, num_classes)
    graph = Neural.build(Nx.axis_size(encoded.x, 1), num_classes)
    preds = graph |> Neural.predict(model_state, holdout.x) |> Nx.argmax(axis: -1)
    metric = holdout.y |> Scholar.Metrics.Classification.accuracy(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "neural_classifier",
       task_type: "classification",
       metric_name: "accuracy",
       metric_value: metric,
       model: model_state,
       classes: encoded.classes,
       sample_count: total_n
     }}
  end

  defp fit_and_score(%Spec{task_type: "regression"}, :neural, encoded, holdout, total_n) do
    model_state = NeuralTrainer.fit_regressor(encoded.x, encoded.y)
    graph = Neural.build(Nx.axis_size(encoded.x, 1), 1)
    preds = graph |> Neural.predict(model_state, holdout.x) |> Nx.squeeze(axes: [1])
    mse = holdout.y |> Scholar.Metrics.Regression.mean_square_error(preds) |> Nx.to_number()

    {:ok,
     %{
       algorithm: "neural_regressor",
       task_type: "regression",
       metric_name: "rmse",
       metric_value: :math.sqrt(max(mse, 0.0)),
       model: model_state,
       classes: nil,
       sample_count: total_n
     }}
  end

  defp fit_forecast(%Spec{} = spec, rows, population) do
    with {:ok, epoch} <- resolve_epoch(rows, spec.time_column) do
      family = family_for(population, spec.family)
      {train_rows, holdout_rows} = split(rows)

      with {:ok, train_enc} <- forecast_encode(train_rows, spec, epoch),
           {:ok, holdout_enc} <- forecast_encode(holdout_rows, spec, epoch) do
        scale = Scaling.fit(train_enc.x)
        scaled_train = %{train_enc | x: Scaling.apply(train_enc.x, scale)}
        scaled_holdout = %{holdout_enc | x: Scaling.apply(holdout_enc.x, scale)}

        # Reuses fit_and_score/5's existing "regression" clauses unchanged (a forecast IS a
        # regression, just with time-derived features) - relabeling only for this one call,
        # never persisted, so the tier-selection logic isn't duplicated for a third time_type.
        {:ok, result} = fit_and_score(%Spec{spec | task_type: "regression"}, family, scaled_train, scaled_holdout, length(rows))
        {:ok, result |> with_scale(scale) |> forecast_result(spec, epoch) |> Map.put(:population, population)}
      end
    end
  end

  defp forecast_result(result, spec, epoch) do
    extra = %{"time_column" => spec.time_column, "epoch" => DateTime.to_iso8601(epoch), "real_feature_columns" => spec.feature_columns}

    result
    |> Map.put(:task_type, "forecast")
    |> Map.put(:extra_params, Map.merge(extra, Map.get(result, :extra_params, %{})))
    |> Map.put(:model_feature_columns, TimeFeatures.synthetic_names() ++ spec.feature_columns)
  end

  defp resolve_epoch(rows, time_column) do
    case parse_times(rows, time_column) do
      {:ok, []} -> {:error, "no rows to determine a time reference point from"}
      {:ok, times} -> {:ok, Enum.min(times, DateTime)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_times(rows, time_column) do
    try_map(rows, fn row ->
      case TimeFeatures.parse(Map.get(row, time_column)) do
        {:ok, dt} -> {:ok, dt}
        :error -> {:error, "time column #{inspect(time_column)} has an unparseable value"}
      end
    end)
  end

  defp forecast_encode(rows, spec, epoch) do
    with {:ok, x} <- forecast_feature_matrix(rows, spec, epoch),
         {:ok, y} <- numeric_target_vector(rows, spec.target_column) do
      {:ok, %{x: Nx.tensor(x, type: :f32), y: y, classes: nil}}
    end
  end

  defp forecast_feature_matrix(rows, spec, epoch) do
    try_map(rows, &forecast_feature_row(&1, spec, epoch))
  end

  defp forecast_feature_row(row, spec, epoch) do
    with {:ok, dt} <- time_or_error(row, spec.time_column),
         {:ok, extra} <- try_map(spec.feature_columns, fn col -> numeric_or_error(row, col, "feature") end) do
      {:ok, TimeFeatures.features(dt, epoch) ++ extra}
    end
  end

  defp time_or_error(row, time_column) do
    case TimeFeatures.parse(Map.get(row, time_column)) do
      {:ok, dt} -> {:ok, dt}
      :error -> {:error, "time column #{inspect(time_column)} has an unparseable value"}
    end
  end

  defp numeric_target_vector(rows, target_column) do
    case try_map(rows, fn row -> numeric_or_error(row, target_column, "target") end) do
      {:ok, values} -> {:ok, Nx.tensor(values, type: :f32)}
      error -> error
    end
  end

  defp numeric_or_error(row, column, kind) do
    case Numeric.to_number(Map.get(row, column)) do
      {:ok, n} -> {:ok, n}
      :error -> {:error, "#{kind} column #{inspect(column)} has a non-numeric value"}
    end
  end

  defp fit_clustering(spec, rows, population) do
    rows = maybe_subsample(rows, @clustering_max_rows)

    with {:ok, x} <- feature_matrix(rows, spec.feature_columns) do
      raw = Nx.tensor(x, type: :f32)
      scale = Scaling.fit(raw)
      tensor = Scaling.apply(raw, scale)
      k_max = min(@max_clusters, max(2, Nx.axis_size(tensor, 0) - 1))

      with {:ok, {model, k, score}} <- best_kmeans(tensor, k_max) do
        labels = Nx.to_flat_list(model.labels)
        {mean_d, stddev_d} = tensor |> point_distances(model.clusters, labels) |> mean_stddev()

        {:ok,
         %{
           algorithm: "kmeans",
           task_type: "clustering",
           metric_name: "silhouette",
           metric_value: score,
           model: model,
           classes: nil,
           sample_count: length(rows),
           population: population,
           extra_params: %{
             "num_clusters" => k,
             "distance_mean" => mean_d,
             "distance_stddev" => stddev_d,
             "clusters" => cluster_summaries(rows, spec.feature_columns, labels, k),
             "scale" => Scaling.to_params(scale)
           }
         }}
      end
    end
  end

  defp maybe_subsample(rows, max) when length(rows) > max, do: rows |> Enum.shuffle() |> Enum.take(max)
  defp maybe_subsample(rows, _max), do: rows

  # Picking k by which score is best ON THE FIT DATA is standard practice for k-means
  # (there's no held-out "ground truth" for an unsupervised split to protect against) -
  # unlike the supervised holdout split above, this isn't cutting a corner.
  #
  # A candidate k that leaves an empty cluster (duplicate-heavy or low-cardinality data)
  # scores :nan, not a float - Nx.to_number's own return for a NaN result. Left in the
  # running, :nan sorts above every float in Erlang's term order and Enum.max_by would pick
  # it as "best", then crash later trying to persist a non-float metric_value. Reject it
  # here instead, and fail the whole fit only if every candidate k degenerated.
  defp best_kmeans(x, k_max) do
    candidates =
      2..k_max
      |> Enum.map(fn k ->
        model = Scholar.Cluster.KMeans.fit(x, num_clusters: k, key: Nx.Random.key(System.unique_integer([:positive])))
        score = x |> Scholar.Metrics.Clustering.silhouette_score(model.labels, num_clusters: k) |> Nx.to_number()
        {model, k, score}
      end)
      |> Enum.reject(fn {_model, _k, score} -> score == :nan end)

    case candidates do
      [] -> {:error, "the data has no separable structure to cluster (too many identical or near-identical rows)"}
      _ -> {:ok, Enum.max_by(candidates, fn {_model, _k, score} -> score end)}
    end
  end

  defp point_distances(x, centroids, labels) do
    x
    |> Nx.to_batched(1)
    |> Enum.zip(labels)
    |> Enum.map(fn {row, label} ->
      centroid = Nx.slice_along_axis(centroids, label, 1, axis: 0)
      Scholar.Metrics.Distance.euclidean(row, centroid) |> Nx.to_number()
    end)
  end

  defp mean_stddev(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - mean, 2) end) / n
    {mean, :math.sqrt(variance)}
  end

  # Human-readable per-cluster summaries - size plus each feature's average - so "describe"
  # can answer "what IS cluster 2" in plain terms instead of only a bare index.
  defp cluster_summaries(rows, feature_columns, labels, k) do
    groups = rows |> Enum.zip(labels) |> Enum.group_by(fn {_row, label} -> label end, fn {row, _label} -> row end)

    for c <- 0..(k - 1) do
      %{"cluster" => c, "size" => length(Map.get(groups, c, [])), "means" => feature_means(Map.get(groups, c, []), feature_columns)}
    end
  end

  defp feature_means([], feature_columns), do: Map.new(feature_columns, &{&1, nil})

  defp feature_means(rows, feature_columns) do
    Map.new(feature_columns, fn col ->
      values = column_values(rows, col)
      {col, if(values == [], do: nil, else: Float.round(Enum.sum(values) / length(values), 4))}
    end)
  end

  defp column_values(rows, col) do
    Enum.flat_map(rows, fn row ->
      case Numeric.to_number(Map.get(row, col)) do
        {:ok, n} -> [n]
        :error -> []
      end
    end)
  end

  # Maps `fun` over `items`, short-circuiting on the first `{:error, _}` - used both for
  # rows -> feature-value lists and rows -> a flat list of target values, so there's one
  # place that decides "stop and report the first bad value" rather than two.
  defp try_map(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
