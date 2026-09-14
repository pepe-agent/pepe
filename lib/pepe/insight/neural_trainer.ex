defmodule Pepe.Insight.NeuralTrainer do
  @moduledoc """
  Fits `Pepe.Insight.Neural`'s fixed architecture. Only called for the large-data tier
  (`Pepe.Insight.Trainer`'s `@large_data_threshold`) - never a user choice.

  Trains against raw logits, not a softmax-activated output, and tells the loss function
  `from_logits: true` explicitly: `Axon.Losses.categorical_cross_entropy/3` silently drops
  the `sparse: true` option whenever it detects `y_pred` came from a layer built with
  `activation: :softmax` (it takes an internal "already logits-like" branch that never
  forwards `sparse` at all) - found by testing the training loop directly, not documented
  anywhere obvious. Keeping the model's own output layer unactivated, and asking for
  softmax/from_logits explicitly in the loss, is what makes `sparse: true` (plain integer
  class labels, matching what `Pepe.Insight.Trainer.encode/3` already produces for the
  Scholar path) actually take effect.

  Runs JIT-compiled via EXLA when it's usable on this machine (`Pepe.Insight.Neural.
  defn_options/0`, scoped to just this `Axon.Loop.run/3` call - never `Nx.default_backend/0`,
  so Scholar/EXGBoost's own tiers are untouched either way). EXLA depends on a precompiled
  XLA binary that exists for Linux/macOS but not native Windows (a native Windows build
  doesn't compile at all without it - see `defn_options/0`'s moduledoc) - on a machine where
  the binary is present but fails to actually load, this falls back to the same plain,
  uncompiled `Nx` backend the neural tier always ran on before EXLA existed: correct either
  way, just slower without it.
  """

  alias Pepe.Insight.Neural

  @epochs 10
  @batch_size 256
  @learning_rate 0.01

  # `struct()`, not the more precise `%Axon.ModelState{}` - see Neural.predict/3's own
  # comment: Axon declares no Axon.ModelState.t/0 for dialyzer, and credo's SpecWithStruct
  # check rejects the bare struct literal the other way. struct() is what satisfies both.
  @spec fit_classifier(Nx.Tensor.t(), Nx.Tensor.t(), pos_integer()) :: struct()
  def fit_classifier(x, y, num_classes) do
    model = Neural.build(Nx.axis_size(x, 1), num_classes)

    loss_fn = fn y_true, y_pred ->
      Axon.Losses.categorical_cross_entropy(y_true, y_pred, reduction: :mean, from_logits: true, sparse: true)
    end

    run(model, loss_fn, x, y)
  end

  @spec fit_regressor(Nx.Tensor.t(), Nx.Tensor.t()) :: struct()
  def fit_regressor(x, y) do
    model = Neural.build(Nx.axis_size(x, 1), 1)
    y2d = Nx.reshape(y, {Nx.axis_size(y, 0), 1})
    run(model, :mean_squared_error, x, y2d)
  end

  defp run(model, loss, x, y) do
    # Nx.to_batched/2 requires batch_size <= the tensor's row count (no auto-padding) - cap
    # to what's actually there instead of assuming @batch_size always fits.
    batch_size = min(@batch_size, Nx.axis_size(x, 0))
    data = Stream.zip(Nx.to_batched(x, batch_size), Nx.to_batched(y, batch_size))
    loop = Axon.Loop.trainer(model, loss, Polaris.Optimizers.adam(learning_rate: @learning_rate), log: 0)
    opts = [epochs: @epochs] ++ Neural.defn_options()
    Axon.Loop.run(loop, data, Axon.ModelState.empty(), opts)
  end
end
