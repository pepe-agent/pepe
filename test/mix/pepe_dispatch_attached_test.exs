defmodule Mix.Tasks.PepeDispatchAttachedTest do
  @moduledoc """
  `dispatch_attached/1` exists so a command run against an already-live node (via
  `bin/pepe rpc`/`remote` from inside a running container) can't flip the global
  `serve_endpoint`/`start_gateways`/`persist_sessions` app env the way a fresh CLI
  process safely can (it exits right after; a live node doesn't). `Pepe.Agent.Session`
  and `Pepe.Gateways.Supervisor.enabled?/0` both read these at *runtime*, not just at
  boot: a corrupted flag silently disables session persistence or Telegram gateway
  restarts for the rest of the server's life. Pinned against every `with_app/2`
  caller, not just `run`/`chat`/`tui`. An earlier version of `dispatch_attached/1`
  only special-cased those three and missed over a dozen others (`eval`, `doctor`,
  `plugin install`, `cron`, ...), so this uses one of the missed ones (`cron`) on
  purpose, not `run`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @keys [:serve_endpoint, :start_gateways, :persist_sessions]

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dispatch_attached_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    saved = Enum.map(@keys, fn key -> {key, Application.get_env(:pepe, key)} end)
    Enum.each(@keys, fn key -> Application.put_env(:pepe, key, :sentinel) end)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} ->
        if value, do: Application.put_env(:pepe, key, value), else: Application.delete_env(:pepe, key)
      end)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "dispatch_attached/1 leaves serve_endpoint/start_gateways/persist_sessions untouched" do
    capture_io(fn -> Mix.Tasks.Pepe.dispatch_attached(["cron"]) end)

    for key <- @keys do
      assert Application.get_env(:pepe, key) == :sentinel, "#{key} was mutated by an attached dispatch"
    end
  end

  test "sanity: plain dispatch/1 (unattached) DOES flip them, proving the test above isn't vacuous" do
    capture_io(fn -> Mix.Tasks.Pepe.dispatch(["cron"]) end)

    refute Application.get_env(:pepe, :start_gateways) == :sentinel
  end
end
