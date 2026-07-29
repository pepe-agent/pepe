defmodule Pepe.DeliveryLedgerTest do
  @moduledoc """
  The delivery ledger's own state machine, independent of any channel: record a reply
  as owed, follow it through attempting/delivered/failed, and prove the boot-time sweep
  claims exactly what a crash would have left behind (and nothing a live delivery is
  still working on, since the whole premise of the sweep is that it runs before
  anything new starts).
  """
  use ExUnit.Case, async: false

  alias Pepe.DeliveryLedger, as: Ledger

  # Every sweep below goes through `sweep/3`, which scopes it to the test's own session key.
  #
  # `sweep_recoverable/2` sees the WHOLE namespace by design - it runs at boot, before
  # anything else has started - and the ledger lives in `Pepe.Store`, which is Mnesia and
  # therefore global to the VM, not isolated per test by `PEPE_HOME` the way `config.json`
  # and the SQLite repo are. A delivery row left behind by any other test in the run is
  # visible here, and an unscoped sweep would not merely see it: it would *claim* it, which
  # breaks that other test too. This file used to sweep unscoped and failed intermittently
  # with another test's row in the result.
  #
  # `setup`, not `setup_all`: each test still wants its own ledger.
  setup do
    home = Path.join(System.tmp_dir!(), "pepe_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      :mnesia.stop()
      :persistent_term.erase({Pepe.Store, :ready})
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp sweep(session, channel \\ "telegram", extra \\ fn _ -> true end),
    do: Ledger.sweep_recoverable(channel, &(&1.session_key == session and extra.(&1)))

  test "a delivered reply leaves no trace to sweep" do
    id = Ledger.record("s1", "telegram", %{chat_id: 1}, "hello")
    Ledger.mark_attempting(id)
    Ledger.mark_delivered(id)

    assert sweep("s1") == []
  end

  test "a row still pending (crashed before the send even started) is claimed plainly" do
    id = Ledger.record("s2", "telegram", %{chat_id: 2}, "never sent")

    [row] = sweep("s2")
    assert row.id == id
    assert row.content == "never sent"
    assert row.needs_marker == false
  end

  test "a row stuck attempting (crashed mid-send) is claimed with the ambiguity marker" do
    id = Ledger.record("s3", "telegram", %{chat_id: 3}, "maybe sent")
    Ledger.mark_attempting(id)

    [row] = sweep("s3")
    assert row.id == id
    assert row.needs_marker == true
  end

  test "a definitively failed row is also claimed with the marker" do
    id = Ledger.record("s4", "telegram", %{chat_id: 4}, "rejected")
    Ledger.mark_attempting(id)
    Ledger.mark_failed(id, "http_error 400")

    [row] = sweep("s4")
    assert row.needs_marker == true
  end

  test "sweeping one channel never claims another channel's rows" do
    Ledger.record("s5", "telegram", %{chat_id: 5}, "tg")
    Ledger.record("s5", "whatsapp", %{chat_id: 5}, "wa")

    assert [%{content: "tg"}] = sweep("s5")
    assert [%{content: "wa"}] = sweep("s5", "whatsapp")
  end

  test "the filter narrows which rows a boot can actually claim (e.g. one bot among several)" do
    Ledger.record("s6", "telegram", %{bot: "alpha"}, "for alpha")
    Ledger.record("s6", "telegram", %{bot: "beta"}, "for beta")

    rows = sweep("s6", "telegram", &(&1.meta.bot == "alpha"))
    assert [%{content: "for alpha"}] = rows
  end

  test "a row retried past the attempt cap is abandoned, not claimed again" do
    id = Ledger.record("s7", "telegram", %{chat_id: 7}, "cursed")

    for _ <- 1..3 do
      Ledger.mark_attempting(id)
      Ledger.mark_failed(id, "still failing")
    end

    assert sweep("s7") == []
  end

  test "record is idempotent for the exact same turn (same session/channel/meta/content)" do
    id1 = Ledger.record("s8", "telegram", %{chat_id: 8}, "same content")
    id2 = Ledger.record("s8", "telegram", %{chat_id: 8}, "same content")

    assert id1 == id2
  end
end
