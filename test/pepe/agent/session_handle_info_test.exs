defmodule Pepe.Agent.SessionHandleInfoTest do
  @moduledoc """
  A live conversation must never crash over a message its GenServer doesn't recognize -
  a stray send from anywhere (a misbehaving plugin process, a leftover ref) drops here
  instead of taking the Session, and everything it's holding, down with it.
  """
  use ExUnit.Case, async: true

  test "an unrecognized message is dropped, not a FunctionClauseError" do
    state = %{}
    assert Pepe.Agent.Session.handle_info(:some_stray_message, state) == {:noreply, state}
    assert Pepe.Agent.Session.handle_info({:garbage, "x", 1}, state) == {:noreply, state}
  end
end
