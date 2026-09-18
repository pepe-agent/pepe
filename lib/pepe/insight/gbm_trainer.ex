defmodule Pepe.Insight.GBMTrainer do
  @moduledoc """
  Fits a gradient-boosted tree ensemble via `EXGBoost` (Elixir bindings for XGBoost) - the
  mid-size tier in `Pepe.Insight.Trainer`'s family selection, and the strongest general
  default for tabular business data at the scale most real operators actually have. Fixed
  round count, no exposed hyperparameter surface - same "Pepe decides" philosophy as
  `Pepe.Insight.NeuralTrainer`.

  Classification always uses `:multi_softmax` with `num_class` set, even for a 2-class
  problem, rather than switching to `:binary_logistic` for that one case - one code path
  regardless of class count, matching how the rest of `Trainer` already treats binary
  classification as an ordinary 2-class case rather than a special one.
  """

  @rounds 100

  @doc """
  Whether this build has the GBM tier at all. EXGBoost publishes a precompiled NIF for
  Linux/macOS only, so the native Windows binary is built without it (`PEPE_SKIP_GBM=1`,
  see `gbm_deps/0` in mix.exs) and `Pepe.Insight.Trainer` must never select this tier
  there: it drops to Scholar's linear/logistic regression instead of reaching an undefined
  `EXGBoost` function.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(EXGBoost)

  @spec fit_classifier(Nx.Tensor.t(), Nx.Tensor.t(), pos_integer()) :: EXGBoost.Booster.t()
  def fit_classifier(x, y, num_classes) do
    EXGBoost.train(x, y, objective: :multi_softmax, num_class: num_classes, num_boost_rounds: @rounds)
  end

  @spec fit_regressor(Nx.Tensor.t(), Nx.Tensor.t()) :: EXGBoost.Booster.t()
  def fit_regressor(x, y) do
    EXGBoost.train(x, y, objective: :reg_squarederror, num_boost_rounds: @rounds)
  end
end
