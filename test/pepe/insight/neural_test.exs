defmodule Pepe.Insight.NeuralTest do
  @moduledoc """
  `Neural.defn_options/0`'s EXLA-usable probe - cached, not re-checked per call. The
  negative case (EXLA present but failing to load, e.g. no precompiled XLA binary for this
  platform) can't be simulated safely in-process without actually breaking the NIF this
  suite otherwise depends on - `neural_trainer_test.exs`/`insight_test.exs`'s large-data
  tier test are what prove training/predicting still completes (just slower) when this
  falls back to `[]`.
  """

  use ExUnit.Case, async: false

  alias Pepe.Insight.Neural

  test "returns [compiler: EXLA] on a machine where EXLA actually works, and caches it" do
    assert Neural.defn_options() == [compiler: EXLA]
    # Second call reads the cached :persistent_term value, not a fresh probe.
    assert Neural.defn_options() == [compiler: EXLA]
  end

  test "build/2 and predict/3 round-trip through the same JIT path defn_options/0 picks" do
    graph = Neural.build(2, 1)
    {init_fn, _predict_fn} = Axon.build(graph)
    state = init_fn.(Nx.template({1, 2}, :f32), Axon.ModelState.empty())

    [value] = graph |> Neural.predict(state, Nx.tensor([[1.0, 2.0]])) |> Nx.to_flat_list()
    assert is_float(value)
  end
end
