defmodule Pepe.Insight.Scaling do
  @moduledoc """
  Per-feature standardization (zero mean, unit variance), fit once from training rows and
  reused identically for scoring the holdout and for every later `predict`. Without this,
  Euclidean distance (`Trainer.fit_clustering/2`, `Predictor`'s `"kmeans"` path) and
  gradient descent (`Scholar.Linear.LogisticRegression`) are both dominated by whichever
  feature happens to have the largest raw scale - age in the 0-100s next to revenue in the
  millions - rather than by which feature actually matters. Fit on the training split only
  (never the holdout, never a later predict call): fitting on anything else would leak
  information the holdout metric is supposed to be honest about.
  """

  @doc "Fit mean/stddev per feature column from `x` (a `{rows, features}` tensor)."
  @spec fit(Nx.Tensor.t()) :: map()
  def fit(x) do
    mean = Nx.mean(x, axes: [0])
    stddev = Nx.standard_deviation(x, axes: [0])
    # A constant column has stddev 0 - dividing by it would produce NaN/inf. Leave such a
    # column's scale at 1.0 instead: subtracting its own mean still centers it at 0, which
    # is harmless, rather than poisoning every downstream computation with a NaN.
    safe_stddev = Nx.select(Nx.less(stddev, 1.0e-8), Nx.tensor(1.0), stddev)
    %{mean: mean, stddev: safe_stddev}
  end

  @doc "Apply a fitted scale to a `{rows, features}` tensor."
  @spec apply(Nx.Tensor.t(), map()) :: Nx.Tensor.t()
  def apply(x, %{mean: mean, stddev: stddev}), do: Nx.divide(Nx.subtract(x, mean), stddev)

  @doc "Encode a fitted scale as plain lists, for JSON storage in `Model.params`."
  @spec to_params(map()) :: map()
  def to_params(%{mean: mean, stddev: stddev}) do
    %{"mean" => Nx.to_flat_list(mean), "stddev" => Nx.to_flat_list(stddev)}
  end

  @doc "The inverse of `to_params/1`."
  @spec from_params(map()) :: map()
  def from_params(%{"mean" => mean, "stddev" => stddev}) do
    %{mean: Nx.tensor(mean, type: :f32), stddev: Nx.tensor(stddev, type: :f32)}
  end
end
