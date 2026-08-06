defmodule Pepe.Slots.HealthTest do
  use ExUnit.Case, async: false

  alias Pepe.Slots.Health

  setup do
    on_exit(fn -> Health.clear("health_test_slot") end)
    :ok
  end

  test "nothing recorded yet returns nil" do
    assert Health.last_failure("health_test_slot") == nil
  end

  test "a recorded failure is readable back, and clear/1 removes it" do
    Health.record_failure("health_test_slot", SomeModule, :timeout)
    assert %{module: SomeModule, reason: :timeout} = Health.last_failure("health_test_slot")

    Health.clear("health_test_slot")
    assert Health.last_failure("health_test_slot") == nil
  end
end
