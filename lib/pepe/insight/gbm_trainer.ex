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
  Whether this build has the GBM tier at all, and can actually use it. Two separate ways
  to not have it: EXGBoost publishes a precompiled NIF for Linux/macOS only, so the native
  Windows binary is built without it at all (`PEPE_SKIP_GBM=1`, see `gbm_deps/0` in
  mix.exs) - `Code.ensure_loaded?(EXGBoost)` alone would correctly say `false` there. But
  a build that DOES compile EXGBoost in can still fail to load the actual native `.so` at
  runtime (a missing system library, a wrong-architecture prebuilt binary - both hit in
  practice), and `Code.ensure_loaded?/1` only checks that the *Elixir* wrapper module
  exists, not that its NIF submodule actually loaded - it would say `true` right up to the
  moment a real call raises `UndefinedFunctionError`. Checking that the `:exgboost` OTP
  application is actually running (started by `Pepe.Application.maybe_start_exgboost/0`,
  which is the one place that already knows whether the NIF load itself succeeded) is what
  makes this accurate either way, so `Pepe.Insight.Trainer` reliably drops to Scholar's
  linear/logistic regression instead of reaching a function that was never really there.
  """
  @spec available?() :: boolean()
  def available?, do: List.keymember?(Application.started_applications(), :exgboost, 0)

  @spec fit_classifier(Nx.Tensor.t(), Nx.Tensor.t(), pos_integer()) :: EXGBoost.Booster.t()
  def fit_classifier(x, y, num_classes) do
    EXGBoost.train(x, y, objective: :multi_softmax, num_class: num_classes, num_boost_rounds: @rounds)
  end

  @spec fit_regressor(Nx.Tensor.t(), Nx.Tensor.t()) :: EXGBoost.Booster.t()
  def fit_regressor(x, y) do
    EXGBoost.train(x, y, objective: :reg_squarederror, num_boost_rounds: @rounds)
  end
end
