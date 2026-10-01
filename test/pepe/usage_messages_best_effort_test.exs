defmodule Pepe.UsageMessagesBestEffortTest do
  @moduledoc """
  Counting a customer message must never cost the conversation: with the usage database
  unavailable, `record/1` logs and returns, where it used to raise inside the session that
  was starting the turn and take that session down with it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pepe.Usage.Messages

  test "record/1 returns :ok and logs when the usage database is not running" do
    if Process.whereis(Pepe.Repo) do
      # Another test left a repo up in this VM; there is nothing unavailable to observe.
      assert :ok = Messages.record(nil)
    else
      log = capture_log(fn -> assert :ok = Messages.record("acme") end)
      assert log =~ "could not count a message"
    end
  end
end
