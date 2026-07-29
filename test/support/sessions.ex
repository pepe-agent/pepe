defmodule Pepe.Test.Sessions do
  @moduledoc """
  Stop every live agent session before a test hands the VM to the next one.

  This closes the mechanism behind a family of intermittent failures that all looked like the
  code under test misbehaving. A gateway dispatches each message into a session process, and
  when a test ends the session is still there, mid-turn. It keeps going, and it resolves its
  model connection *when it makes the call*, not when the run started - so it reads the config
  the next test has by then written, calls that test's mock, on that test's port, with that
  test's api key, and its message lands in that test's mailbox looking like legitimate traffic.

  Pinning the assertion is not a general answer to this, because the leaked run can be made to
  look like anything the next test looks like. Ending the run is.

  Registered from `setup` **after** the test's own cleanup callback, since ExUnit runs `on_exit`
  in reverse order of registration: sessions have to die while the config and `PEPE_HOME` they
  are running against still exist.
  """

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor

  @doc "Cancel and terminate every session registered right now. Safe when there are none."
  @spec stop_all!() :: :ok
  def stop_all! do
    # A test that never started the supervision tree has no registry to read. Guarded rather
    # than rescued: a real error from stopping a session must be loud, not swallowed by the very
    # helper that exists to stop things silently going wrong.
    if Process.whereis(Pepe.Agent.Registry) do
      Enum.each(SessionSupervisor.list(), &stop_one/1)
    end

    :ok
  end

  # `Session.stop/1` before terminating, because terminating the supervised GenServer does NOT
  # reach the run: `Pepe.Agent.Session.spawn_run/7` starts the turn with an unlinked
  # `Task.start` and only monitors it, and the session neither traps exits nor defines
  # `terminate/2`. So the task - where the model calls and the tool executions actually happen -
  # outlives the supervisor killing its session. `stop/1` is what kills it (via
  # `cancel_running/2`'s `Process.exit(pid, :kill)`), which is exactly why the product's own
  # `/stop` command goes through it rather than terminating the process.
  defp stop_one(key) do
    Session.stop(key)
    SessionSupervisor.terminate(key)
  catch
    # The session can die between being listed and being reached, which is already the outcome
    # this wants.
    :exit, _ -> :ok
  end
end
