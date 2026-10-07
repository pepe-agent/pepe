defmodule Pepe.SeenChannelsTest do
  use ExUnit.Case, async: false

  alias Pepe.SeenChannels

  setup do
    # The throttle table is owned by the app's own Pepe.SeenChannels process.
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_seen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  @t0 1_700_000_000

  test "the first message creates the channel, later ones refresh it at most once a minute" do
    assert :new = SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
    assert [%{channel: "C1", provider: "slack", kind: "group", first_seen: @t0, last_seen: @t0}] = SeenChannels.list("desk")

    # Ten seconds later: within the throttle, nothing is written.
    assert :skipped = SeenChannels.touch("desk", "slack", "C1", now: @t0 + 10)
    assert [%{last_seen: @t0}] = SeenChannels.list("desk")

    # A minute later: last activity moves, first sight stays.
    later = @t0 + 61
    assert :seen = SeenChannels.touch("desk", "slack", "C1", now: later)
    assert [%{first_seen: @t0, last_seen: ^later}] = SeenChannels.list("desk")
  end

  test "a name or a kind that arrives later fills the row, and a missing one never wipes it" do
    assert :new = SeenChannels.touch("desk", "slack", "C1", now: @t0)
    assert [%{name: nil, kind: nil}] = SeenChannels.list("desk")

    assert :seen = SeenChannels.touch("desk", "slack", "C1", kind: "group", name: "#ops", now: @t0 + 100)
    assert [%{name: "#ops", kind: "group"}] = SeenChannels.list("desk")

    assert :seen = SeenChannels.touch("desk", "slack", "C1", name: "  ", now: @t0 + 200)
    assert [%{name: "#ops", kind: "group"}] = SeenChannels.list("desk")

    # A kind the code does not know is dropped rather than stored.
    assert :seen = SeenChannels.touch("desk", "slack", "C1", kind: "thread", now: @t0 + 300)
    assert [%{kind: "group"}] = SeenChannels.list("desk")
  end

  test "the same channel id on two connections is two separate rows" do
    assert :new = SeenChannels.touch("desk", "slack", "C1", now: @t0)
    assert :new = SeenChannels.touch("sales", "slack", "C1", now: @t0)

    assert [%{connection: "desk", channel: "C1"}] = SeenChannels.list("desk")
    assert [%{connection: "sales", channel: "C1"}] = SeenChannels.list("sales")
  end

  test "the list is most recent first, and a looked-up name is stored" do
    SeenChannels.touch("desk", "slack", "C1", now: @t0)
    SeenChannels.touch("desk", "slack", "D2", now: @t0 + 5)
    SeenChannels.touch("desk", "slack", "C3", now: @t0 + 2)

    assert ["D2", "C3", "C1"] = SeenChannels.list("desk") |> Enum.map(& &1.channel)

    :ok = SeenChannels.put_name("desk", "C1", "#general")
    assert %{name: "#general"} = SeenChannels.list("desk") |> Enum.find(&(&1.channel == "C1"))
  end

  test "removing a connection forgets its channels and nobody else's" do
    SeenChannels.touch("desk", "slack", "C1", now: @t0)
    SeenChannels.touch("sales", "slack", "C1", now: @t0)

    :ok = SeenChannels.delete_connection("desk")

    assert [] = SeenChannels.list("desk")
    assert [%{channel: "C1"}] = SeenChannels.list("sales")
  end

  test "without the repo nothing is recorded and nothing raises" do
    stop_supervised!(Pepe.Repo)

    assert :error = SeenChannels.touch("desk", "slack", "C1", now: @t0)
    assert [] = SeenChannels.list("desk")
    assert :ok = SeenChannels.put_name("desk", "C1", "#ops")
    assert :ok = SeenChannels.delete_connection("desk")
  end
end
