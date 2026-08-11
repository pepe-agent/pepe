defmodule Pepe.Heartbeat.Interval do
  @moduledoc """
  Default `heartbeat_interval` slot occupant: always allows a due pulse, today's behavior
  unchanged. See `Pepe.Slots` for the slot mechanism.
  """

  def name, do: "builtin"
  def slot, do: "heartbeat_interval"
  def allowed?(_project), do: {:ok, true}
end
