defmodule Pepe.Test.LedgerDrain do
  @moduledoc """
  Empty the delivery ledger before a test that boots a channel gateway.

  `Pepe.DeliveryLedger` is backed by `Pepe.Store` (Mnesia), which is global to the VM rather
  than isolated per test by `PEPE_HOME` the way `config.json` and the SQLite repo are. Every
  reply a gateway sends is recorded there as owed, and a row still unclaimed when its test
  ends survives into the next one - where booting a gateway sweeps it and *delivers* it, so
  an unrelated test's next assertion gets `"♻️ Recovered reply - ..."` carrying somebody
  else's content. That is a real failure, seen in two different tests on two different runs,
  and it looks exactly like the code under test misbehaving.

  Draining here rather than cleaning up afterwards is deliberate: a test cannot be sure the
  test before it cleaned up, but it can always make sure it starts empty.

  Not `:mnesia.stop()`, which is what the ledger's own tests do: `Pepe.Store` also holds
  session history, so tearing the whole store down between tests breaks gateway tests that
  depend on a conversation surviving from one message to the next.
  """

  alias Pepe.DeliveryLedger

  @channels ~w(telegram whatsapp)

  @doc "Claim and retire every row left in the ledger, whichever test left it."
  @spec drain!() :: :ok
  def drain! do
    for channel <- @channels,
        row <- DeliveryLedger.sweep_recoverable(channel),
        do: DeliveryLedger.mark_delivered(row.id)

    :ok
  end
end
