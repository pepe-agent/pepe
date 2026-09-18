defmodule Pepe.Insight.Trainer do
  @moduledoc """
  Fetches rows (via `Pepe.Insight.Source`, regardless of `source_kind`) and fits one
  algorithm, picked automatically by default - "Pepe decides", never a required user
  choice. `spec.family` is the one deliberate exception: an operator who already knows
  which family they want (`"linear"`, `"gbm"`, or `"neural"`) can set it explicitly and
  `family_for/2` honors it outright, skipping the volume-based heuristic below entirely -
  automatic is the default *because* nobody has to think about this, not because the
  choice is hidden from whoever wants to make it themselves.

  `"neural"` is the one family a build can be missing (`Pepe.Insight.Neural.available?/0` -
  the native Windows binary is built without it, since EXLA has no precompiled XLA archive
  for that platform). There, asking for it explicitly is refused with a plain message, and
  the automatic choice tops out at `"gbm"` instead of reaching for a tier that isn't there.

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

  Scored by `@cv_folds` (`@cv_folds_neural` for the neural tier)-fold cross-validation, never
  the training rows: each fold fits on its own share and scores on the rest, and the reported
  `metric_value` is the average across every fold - a single random 80/20 split can report a
  misleadingly optimistic or pessimistic number purely from how the shuffle happened to fall,
  and cross-validation is the standard fix. The model actually persisted and served by
  `predict` is a *separate*, final fit on every available row (never just one fold's share) -
  cross-validation exists to produce an honest metric, not to decide which 80% of the data the
  production model gets to learn from.

  Every feature column is standardized (`Pepe.Insight.Scaling`, zero mean/unit variance)
  before any of the above sees it - fit fresh per fold (on that fold's training share only,
  never its validation share) for scoring, and fit once more on every row for the final
  model. Without this, a raw column's native units (age in the 0-100s next to revenue in the
  millions) silently dominate both k-means distance and logistic regression's gradient
  descent - "nothing to tune" has to include not needing to know this exists, not just not
  being asked to set it.

  A feature column doesn't have to be numeric: `Pepe.Insight.Categorical` one-hot encodes any
  column that isn't (`"plan_tier"`, `"region"`, ...), resolved once from every fetched row
  before any split - the same pre-split timing `resolve_classes/2` already uses for a
  classification target, and for the same reason: a rare category landing entirely in one
  fold by chance must not change what the vocabulary is. Scoped to
  classification/regression/forecast; `"clustering"` still requires all-numeric features (see
  `fit_clustering/2`'s own note).

  For `"clustering"` specs (no target column - there's nothing to hold out or predict),
  `Scholar.Cluster.KMeans` fits every candidate cluster count from 2 to `@max_clusters` and
  keeps whichever scores best on `Scholar.Metrics.Clustering.silhouette_score/3` - picking
  `k` on the fit data is the standard way to choose it for k-means, unlike a supervised
  accuracy number, so this does not need cross-validation to stay honest. The same fitted
  model also answers "how anomalous is this point": each training point's distance to its
  own cluster's centroid becomes a mean/stddev baseline (`Predictor` turns a new point's
  distance into a z-score against that baseline) - one model serves both capabilities
  instead of training two. Silhouette scoring is O(n^2), so clustering fits on at most
  `@clustering_max_rows` rows, a random subsample when the source hands back more.

  For `"forecast"` specs (a `target_column` plus a `time_column`, no target/time leakage
  concern beyond the usual cross-validation), `Pepe.Insight.TimeFeatures` turns each row's
  timestamp into 5 numeric features (elapsed time since the training set's earliest
  timestamp, plus cyclical day-of-week/month encodings) prepended to any real
  `feature_columns` (numeric or categorical, same as above), and the result is fit through
  the exact same three-tier family selection as `"regression"` - a forecast is just a
  regression whose features happen to be derived from a clock instead of typed in.
  `fit_forecast/3` reuses `cross_validate_and_fit/5` directly (passing it a spec relabeled
  `"regression"` for that one call) rather than duplicating the tier-selection/CV logic.

  Everything from `encode/4`/`feature_matrix/3` down takes plain Elixir rows and needs no
  live connection, so it's unit-testable with fixtures; only `Source.fetch/3`'s `"db"`
  branch needs a real Postgres to exercise (same gap `test/pepe/tools/db_query_test.exs`
  already documents and defers to manual verification).
  """

  alias Pepe.Insight.Categorical
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
  # Cross-validation fold count. Lower for :neural (already the most expensive tier to fit,
  # at NeuralTrainer's @epochs 10 per fit) so the added cost of scoring stays bounded - 5
  # folds + 1 final fit there would be 6x today's per-training cost for the tier that can
  # least afford it, versus 4x for the cheaper tiers.
  @cv_folds 5
  @cv_folds_neural 3

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
         {:ok, clean_rows, _dropped} <- drop_incomplete_rows(rows, [spec.target_column], spec.feature_columns),
         :ok <- check_row_count(clean_rows) do
      fit_forecast(spec, clean_rows, population)
    end
  end

  def train(%Spec{} = spec, ctx) do
    numeric_columns = if spec.task_type == "regression", do: [spec.target_column], else: []

    with {:ok, population} <- Source.row_count(spec, ctx),
         {:ok, fetched} <- Source.fetch(spec, ctx, population),
         {:ok, rows, _dropped} <- drop_incomplete_rows(fetched, numeric_columns, spec.feature_columns),
         :ok <- check_row_count(rows),
         # Classes/categories are resolved from every fetched row, before any split - not
         # from one fold's training share alone. A rare class/category can land entirely in
         # one fold by chance, and deriving either from a fold's rows only would then reject
         # (or silently reshape) a genuinely valid dataset just because of how the shuffle
         # happened to fall.
         {:ok, classes} <- resolve_classes(rows, spec),
         {:ok, categories} <- Categorical.resolve(rows, spec.feature_columns),
         {:ok, family} <- family_for(population, spec.family) do
      encode_fn = fn subset -> encode(subset, spec, classes, categories) end

      with {:ok, result} <- cross_validate_and_fit(spec, family, rows, encode_fn, length(rows)) do
        {:ok, result |> with_categories(categories) |> Map.put(:population, population)}
      end
    end
  end

  # A missing value in a checked column drops just that row instead of aborting the whole
  # fit - up to @max_dropped_ratio of the batch, past which something is wrong enough (bad
  # column, bad table) that failing loudly beats training on a small remainder.
  # `numeric_columns` must parse as a number (a target/time column); `presence_columns` just
  # can't be missing/blank - whether one of those is numeric or categorical is decided later,
  # by `Categorical.resolve/2`, once the row set is already clean.
  defp drop_incomplete_rows(rows, numeric_columns, presence_columns \\ []) do
    total = length(rows)

    clean =
      Enum.filter(rows, fn row ->
        Enum.all?(numeric_columns, fn col -> numeric?(Map.get(row, col)) end) and
          Enum.all?(presence_columns, fn col -> present?(Map.get(row, col)) end)
      end)

    dropped = total - length(clean)

    if total > 0 and dropped / total > @max_dropped_ratio do
      {:error, "too many rows (#{dropped}/#{total}) have a missing value in #{inspect(numeric_columns ++ presence_columns)}"}
    else
      {:ok, clean, dropped}
    end
  end

  defp numeric?(value), do: match?({:ok, _}, Numeric.to_number(value))
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp with_extra(result, extra_params) do
    extra = Map.merge(Map.get(result, :extra_params, %{}), extra_params)
    Map.put(result, :extra_params, extra)
  end

  defp with_categories(result, categories) when map_size(categories) == 0, do: result
  defp with_categories(result, categories), do: with_extra(result, %{"categories" => categories})

  defp resolve_classes(rows, %Spec{task_type: "classification", target_column: col}) do
    classes = rows |> Enum.map(&Categorical.to_label(Map.get(&1, col))) |> Enum.uniq() |> Enum.sort()

    case classes do
      [_, _ | _] -> {:ok, classes}
      _ -> {:error, "target column #{inspect(col)} needs at least 2 distinct classes to train a classifier"}
    end
  end

  defp resolve_classes(_rows, _spec), do: {:ok, nil}

  # An explicit spec.family override (an operator who knows exactly which family they want)
  # always wins over the automatic, volume-based choice - nil (the default) is what leaves
  # Pepe to decide. Asking for a family this build doesn't have is the one override that
  # gets refused, with a plain message rather than an UndefinedFunctionError at fit time.
  defp family_for(_population, "linear"), do: {:ok, :linear}
  defp family_for(_population, "gbm"), do: {:ok, :gbm}

  defp family_for(_population, "neural") do
    if Neural.available?(),
      do: {:ok, :neural},
      else: {:error, "the neural family isn't available in this build - use \"gbm\" or leave family unset"}
  end

  defp family_for(population, _override), do: {:ok, auto_family_for(population)}

  # A build without the neural tier (PEPE_SKIP_NEURAL=1, see mix.exs) tops out at GBM: the
  # automatic choice is Pepe's to make and must always land on something that actually
  # runs, so the largest tier degrades to the next one down rather than erroring. Gradient
  # boosting is a competitive model at this volume anyway - it's the tier the neural net
  # has to beat, not a consolation prize.
  defp auto_family_for(population) when population >= @large_data_threshold,
    do: if(Neural.available?(), do: :neural, else: :gbm)

  defp auto_family_for(population) when population >= @small_data_threshold, do: :gbm
  defp auto_family_for(_population), do: :linear

  defp check_row_count(rows) do
    if length(rows) >= @min_rows,
      do: :ok,
      else: {:error, "needs at least #{@min_rows} example rows to train (found #{length(rows)})"}
  end

  # Deals rows into `k` roughly-equal, disjoint folds and yields each `{train, val}` split in
  # turn (val = one fold, train = every other fold) - one shuffle shared across every fold,
  # so no row can land in more than one fold's validation share.
  defp k_fold_split(rows, k) do
    chunks =
      rows
      |> Enum.shuffle()
      |> Enum.with_index()
      |> Enum.group_by(fn {_row, i} -> rem(i, k) end, fn {row, _i} -> row end)
      |> Map.values()

    for i <- 0..(k - 1) do
      val = Enum.at(chunks, i, [])
      train = chunks |> List.delete_at(i) |> List.flatten()
      {train, val}
    end
  end

  defp fold_count(family, n) do
    base = if family == :neural, do: @cv_folds_neural, else: @cv_folds
    max(2, min(base, div(n, 4)))
  end

  # Cross-validates `family` over `rows` (via `encode_fn`, already closed over the
  # pre-resolved classes/categories/epoch it needs) for an honest `metric_value`, then fits
  # one final model on every row - the model actually persisted and served, never just one
  # fold's share. `encode_fn` lets this one function serve both the plain
  # classification/regression path (`encode/4`) and the forecast path (`forecast_encode/4`)
  # without either duplicating the fold/scale/fit machinery.
  defp cross_validate_and_fit(spec, family, rows, encode_fn, total_n) do
    k = fold_count(family, length(rows))
    folds = k_fold_split(rows, k)

    with {:ok, scored} <- score_folds(spec, family, folds, encode_fn),
         {:ok, encoded} <- encode_fn.(rows) do
      [{metric_name, _value} | _] = scored
      {avg, stddev} = scored |> Enum.map(fn {_name, value} -> value end) |> mean_stddev()

      scale = Scaling.fit(encoded.x)
      scaled = %{encoded | x: Scaling.apply(encoded.x, scale)}
      {model, algorithm} = fit_by_family(spec, family, scaled)

      result = %{
        algorithm: algorithm,
        task_type: spec.task_type,
        metric_name: metric_name,
        metric_value: avg,
        model: model,
        classes: encoded.classes,
        sample_count: total_n
      }

      extra = %{
        "scale" => Scaling.to_params(scale),
        "cv_folds" => k,
        "metric_stddev" => stddev,
        "input_width" => Nx.axis_size(scaled.x, 1)
      }

      {:ok, with_extra(result, extra)}
    end
  end

  defp score_folds(spec, family, folds, encode_fn) do
    folds
    |> Enum.reduce_while({:ok, []}, fn {train_rows, val_rows}, {:ok, acc} ->
      case fold_score(spec, family, train_rows, val_rows, encode_fn) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp fold_score(spec, family, train_rows, val_rows, encode_fn) do
    with {:ok, train_enc} <- encode_fn.(train_rows),
         {:ok, val_enc} <- encode_fn.(val_rows) do
      # Fit the scale on this fold's training share only, never its validation share -
      # fitting on both would leak that fold's validation distribution into its own score.
      scale = Scaling.fit(train_enc.x)
      scaled_train = %{train_enc | x: Scaling.apply(train_enc.x, scale)}
      scaled_val = %{val_enc | x: Scaling.apply(val_enc.x, scale)}
      {model, _algorithm} = fit_by_family(spec, family, scaled_train)
      {:ok, score(spec, family, model, scaled_train, scaled_val)}
    end
  end

  @doc false
  @spec encode([map()], Spec.t(), [String.t()] | nil, map()) :: {:ok, map()} | {:error, String.t()}
  def encode(rows, %Spec{} = spec, classes, categories \\ %{}) do
    with {:ok, x} <- feature_matrix(rows, spec.feature_columns, categories),
         {:ok, y, out_classes} <- target_vector(rows, spec, classes) do
      {:ok, %{x: Nx.tensor(x, type: :f32), y: y, classes: out_classes}}
    end
  end

  defp feature_matrix(rows, feature_columns, categories) do
    try_map(rows, &Categorical.feature_vector(&1, feature_columns, categories))
  end

  defp target_vector(rows, %Spec{task_type: "regression", target_column: col}, _classes) do
    case try_map(rows, fn row -> numeric_or_error(row, col, "target") end) do
      {:ok, values} -> {:ok, Nx.tensor(values, type: :f32), nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_vector(rows, %Spec{task_type: "classification", target_column: col}, nil) do
    labels = Enum.map(rows, &Categorical.to_label(Map.get(&1, col)))
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
    labels = Enum.map(rows, &Categorical.to_label(Map.get(&1, col)))
    {:ok, Nx.tensor(Enum.map(labels, &Map.get(index, &1, -1)), type: {:s, 64}), classes}
  end

  defp fit_by_family(%Spec{task_type: "classification"}, :linear, encoded) do
    num_classes = length(encoded.classes)
    model = Scholar.Linear.LogisticRegression.fit(encoded.x, encoded.y, num_classes: num_classes)
    {model, "logistic_regression"}
  end

  defp fit_by_family(%Spec{task_type: "regression"}, :linear, encoded) do
    {Scholar.Linear.LinearRegression.fit(encoded.x, encoded.y), "linear_regression"}
  end

  defp fit_by_family(%Spec{task_type: "classification"}, :gbm, encoded) do
    num_classes = length(encoded.classes)
    {GBMTrainer.fit_classifier(encoded.x, encoded.y, num_classes), "gbm_classifier"}
  end

  defp fit_by_family(%Spec{task_type: "regression"}, :gbm, encoded) do
    {GBMTrainer.fit_regressor(encoded.x, encoded.y), "gbm_regressor"}
  end

  defp fit_by_family(%Spec{task_type: "classification"}, :neural, encoded) do
    num_classes = length(encoded.classes)
    {NeuralTrainer.fit_classifier(encoded.x, encoded.y, num_classes), "neural_classifier"}
  end

  defp fit_by_family(%Spec{task_type: "regression"}, :neural, encoded) do
    {NeuralTrainer.fit_regressor(encoded.x, encoded.y), "neural_regressor"}
  end

  defp score(%Spec{task_type: "classification"}, :linear, model, _encoded, holdout) do
    preds = Scholar.Linear.LogisticRegression.predict(model, holdout.x)
    {"accuracy", accuracy(holdout.y, preds)}
  end

  defp score(%Spec{task_type: "regression"}, :linear, model, _encoded, holdout) do
    {"rmse", rmse(holdout.y, Scholar.Linear.LinearRegression.predict(model, holdout.x))}
  end

  defp score(%Spec{task_type: "classification"}, :gbm, model, _encoded, holdout) do
    {"accuracy", accuracy(holdout.y, EXGBoost.predict(model, holdout.x))}
  end

  defp score(%Spec{task_type: "regression"}, :gbm, model, _encoded, holdout) do
    {"rmse", rmse(holdout.y, EXGBoost.predict(model, holdout.x))}
  end

  defp score(%Spec{task_type: "classification"}, :neural, model, encoded, holdout) do
    num_classes = length(encoded.classes)
    graph = Neural.build(Nx.axis_size(holdout.x, 1), num_classes)
    preds = graph |> Neural.predict(model, holdout.x) |> Nx.argmax(axis: -1)
    {"accuracy", accuracy(holdout.y, preds)}
  end

  defp score(%Spec{task_type: "regression"}, :neural, model, _encoded, holdout) do
    graph = Neural.build(Nx.axis_size(holdout.x, 1), 1)
    preds = graph |> Neural.predict(model, holdout.x) |> Nx.squeeze(axes: [1])
    {"rmse", rmse(holdout.y, preds)}
  end

  defp accuracy(y_true, y_pred), do: y_true |> Scholar.Metrics.Classification.accuracy(y_pred) |> Nx.to_number()

  defp rmse(y_true, y_pred) do
    mse = y_true |> Scholar.Metrics.Regression.mean_square_error(y_pred) |> Nx.to_number()
    :math.sqrt(max(mse, 0.0))
  end

  defp fit_forecast(%Spec{} = spec, rows, population) do
    with {:ok, epoch} <- resolve_epoch(rows, spec.time_column),
         {:ok, categories} <- Categorical.resolve(rows, spec.feature_columns),
         {:ok, family} <- family_for(population, spec.family) do
      encode_fn = fn subset -> forecast_encode(subset, spec, epoch, categories) end

      # Reuses cross_validate_and_fit/5's existing "regression" clauses unchanged (a forecast
      # IS a regression, just with time-derived features) - relabeling only for this one
      # call, never persisted, so the tier-selection/CV logic isn't duplicated for a third
      # time_type.
      with {:ok, result} <- cross_validate_and_fit(%Spec{spec | task_type: "regression"}, family, rows, encode_fn, length(rows)) do
        {:ok, result |> with_categories(categories) |> forecast_result(spec, epoch) |> Map.put(:population, population)}
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

  defp forecast_encode(rows, spec, epoch, categories) do
    with {:ok, x} <- forecast_feature_matrix(rows, spec, epoch, categories),
         {:ok, y} <- numeric_target_vector(rows, spec.target_column) do
      {:ok, %{x: Nx.tensor(x, type: :f32), y: y, classes: nil}}
    end
  end

  defp forecast_feature_matrix(rows, spec, epoch, categories) do
    try_map(rows, &forecast_feature_row(&1, spec, epoch, categories))
  end

  defp forecast_feature_row(row, spec, epoch, categories) do
    with {:ok, dt} <- time_or_error(row, spec.time_column),
         {:ok, extra} <- Categorical.feature_vector(row, spec.feature_columns, categories) do
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

    with {:ok, x} <- feature_matrix(rows, spec.feature_columns, %{}) do
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
  # unlike the supervised cross-validation above, this isn't cutting a corner.
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
