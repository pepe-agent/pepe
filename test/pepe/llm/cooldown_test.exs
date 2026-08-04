defmodule Pepe.LLM.CooldownTest do
  @moduledoc """
  Pure unit coverage for the cooldown table itself - the behavioral proof that a cooling-down
  model is actually skipped in the failover chain lives in `test/pepe/agent_loop_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Model
  alias Pepe.LLM.Cooldown

  test "a model starts out not cooling down" do
    refute Cooldown.cooling_down?(%Model{id: "unused-#{System.unique_integer([:positive])}", name: "x"})
  end

  test "mark_failed/2 puts a model in cooldown; clear/1 lifts it" do
    model = %Model{id: "m-#{System.unique_integer([:positive])}", name: "x"}

    Cooldown.mark_failed(model, {:http_error, 500, "boom"})
    assert Cooldown.cooling_down?(model)

    Cooldown.clear(model)
    refute Cooldown.cooling_down?(model)
  end

  test "a 429 cools down longer than a generic transient failure" do
    assert Cooldown.duration_ms({:http_error, 429, "rate limited"}) >
             Cooldown.duration_ms(%Req.TransportError{reason: :econnrefused})
  end

  test "id: nil falls back to name, so two ad-hoc single-connection overrides with the same name share one cooldown" do
    same_name_a = %Model{id: nil, name: "shared"}
    same_name_b = %Model{id: nil, name: "shared"}

    Cooldown.mark_failed(same_name_a, {:http_error, 500, "boom"})
    # Same key (id: nil, name: "shared" -> both key on "shared") - this is the accepted
    # tradeoff documented in the module: a rare, cosmetic collision, not a wrong answer.
    assert Cooldown.cooling_down?(same_name_b)
  end

  test "distinct names never collide, even both with id: nil" do
    a = %Model{id: nil, name: "distinct-a-#{System.unique_integer([:positive])}"}
    b = %Model{id: nil, name: "distinct-b-#{System.unique_integer([:positive])}"}

    Cooldown.mark_failed(a, {:http_error, 500, "boom"})
    refute Cooldown.cooling_down?(b)
  end
end
