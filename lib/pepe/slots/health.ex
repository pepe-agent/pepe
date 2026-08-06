defmodule Pepe.Slots.Health do
  @moduledoc """
  Last-failure memory for a slot's non-default occupant, so `mix pepe slot list` and
  `Pepe.Doctor`'s slot check can surface "still configured, but its last call failed" -
  not just "not installed at all" (`Pepe.Slots.status/0`'s `degraded?`, which only covers
  a missing/non-claiming plugin). Written by `Pepe.Slots.Guard` on every fallback to the
  default; cleared on the occupant's next clean success.
  """

  @doc "Record that `slot`'s occupant `mod` failed with `reason`."
  def record_failure(slot, mod, reason) do
    :persistent_term.put(key(slot), %{module: mod, reason: reason, at: DateTime.utc_now()})
  end

  @doc "Clear any recorded failure for `slot` (a subsequent call succeeded)."
  def clear(slot), do: :persistent_term.erase(key(slot))

  @doc "The last recorded failure for `slot`, or nil."
  def last_failure(slot), do: :persistent_term.get(key(slot), nil)

  defp key(slot), do: {__MODULE__, slot}
end
