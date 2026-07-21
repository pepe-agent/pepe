defmodule Pepe.Repo do
  @moduledoc """
  The operational-data store: commitments today, more to come (watches, board,
  traces, usage) - not `config.json`, which stays a plain file for definitions
  (agents, models, channels) that don't grow with usage.

  A single SQLite file under `PEPE_HOME`, mirroring where `Pepe.Store` (Mnesia)
  already puts its own data (`Pepe.Store.start_mnesia/0`).
  """
  use Ecto.Repo,
    otp_app: :pepe,
    adapter: Ecto.Adapters.SQLite3

  # Computed fresh at every start_link, never at compile/config time: PEPE_HOME can
  # change after this module is compiled (a `mix pepe` one-shot resolves the final
  # home before booting the app; every test sets it per-test, long before Repo starts
  # for that test). Reading Config.home() here, not baking a path into config.exs,
  # is what makes both of those work without any special-casing.
  @impl true
  def init(_type, config) do
    path = Path.join([Pepe.Config.home(), "data", "pepe.db"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, Keyword.put(config, :database, path)}
  end
end
