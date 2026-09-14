defmodule Pepe.Insight.Neural do
  @moduledoc """
  The one fixed neural-net architecture `Pepe.Insight` uses for its large-data tier (see
  `Pepe.Insight.Trainer`'s `@large_data_threshold`) - no exposed hyperparameters, same
  "Pepe decides, not the user" philosophy as the small-data Scholar path: an operator with
  hundreds of millions of rows gets a model that can actually use that scale, without
  needing an ML team to pick an architecture.

  Two hidden `Dense(relu)` layers, output is always raw logits/a single linear unit -
  never a baked-in final activation. `Pepe.Insight.NeuralTrainer`'s moduledoc explains why
  that matters (it's not a style choice).
  """

  require Logger

  @spec build(pos_integer(), pos_integer()) :: Axon.t()
  def build(input_dim, output_dim) do
    Axon.input("input", shape: {nil, input_dim})
    |> Axon.dense(32, activation: :relu)
    |> Axon.dense(16, activation: :relu)
    |> Axon.dense(output_dim)
  end

  @doc """
  `Axon.predict/4`, JIT-compiled via EXLA when it's usable on this machine, falling back to
  the plain `Nx` backend otherwise - the predict-time half of the same EXLA-or-fall-back
  choice `Pepe.Insight.NeuralTrainer.run/4` makes at train time, and for the same reason
  (no precompiled XLA binary on some platforms - see `defn_options/0`).
  """
  # `struct()`, not the more precise `%Axon.ModelState{}`: Axon never declares
  # `Axon.ModelState.t()` (dialyzer would then flag it unknown - see NeuralTrainer's own
  # spec on the write side), and credo's own SpecWithStruct check rejects a bare struct
  # literal in a @spec the other way. `struct()` is the one form both tools accept.
  @spec predict(Axon.t(), struct(), Nx.Tensor.t()) :: Nx.Tensor.t()
  def predict(graph, model_state, tensor), do: Axon.predict(graph, model_state, tensor, defn_options())

  @doc """
  `[compiler: EXLA]` if EXLA actually works on this machine, `[]` otherwise - checked once
  per VM and cached, not per call. A real EXLA failure (the .so failing to load - missing
  libstdc++, an incompatible glibc, no precompiled XLA archive for this OS/arch at all)
  surfaces as an `exit` from a GenServer call inside `EXLA.Client`, not a raised exception -
  a plain `try/rescue` around an actual training/predict call never catches it, so it has to
  be ruled out up front with a real probe (`catch :exit, _` included) instead.
  """
  @spec defn_options() :: keyword()
  def defn_options do
    case :persistent_term.get({__MODULE__, :exla_usable}, :unchecked) do
      :unchecked -> check_and_cache_exla()
      true -> [compiler: EXLA]
      false -> []
    end
  end

  defp check_and_cache_exla do
    usable = exla_usable?()

    unless usable do
      Logger.warning("insight: EXLA unavailable, the neural tier will train/predict uncompiled (slower)")
    end

    :persistent_term.put({__MODULE__, :exla_usable}, usable)
    if usable, do: [compiler: EXLA], else: []
  end

  defp exla_usable? do
    Code.ensure_loaded?(EXLA) and probe_exla() == 2
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp probe_exla, do: Nx.Defn.jit(&Nx.add(&1, 1), compiler: EXLA).(Nx.tensor(1)) |> Nx.to_number()
end
