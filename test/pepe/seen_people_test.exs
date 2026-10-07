defmodule Pepe.SeenPeopleTest do
  use ExUnit.Case, async: false

  alias Pepe.SeenPeople
  alias PepeWeb.TrainersPicker

  setup do
    # The throttle table is owned by the app's own Pepe.SeenChannels process.
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_people_#{System.unique_integer([:positive])}")
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

  test "the first message creates the person, later ones refresh them at most once a minute" do
    assert :new = SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)
    assert [%{channel: "C1", person: "U2", name: "Ana", first_seen: @t0, last_seen: @t0}] = SeenPeople.list("desk")

    assert :skipped = SeenPeople.touch("desk", "C1", "U2", now: @t0 + 10)
    assert [%{last_seen: @t0}] = SeenPeople.list("desk")

    later = @t0 + 61
    assert :seen = SeenPeople.touch("desk", "C1", "U2", now: later)
    assert [%{first_seen: @t0, last_seen: ^later}] = SeenPeople.list("desk")
  end

  test "a name that arrives later fills the row, and a missing one never wipes it" do
    SeenPeople.touch("desk", "C1", "U2", now: @t0)
    assert [%{name: nil}] = SeenPeople.list("desk")

    SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0 + 100)
    assert [%{name: "Ana"}] = SeenPeople.list("desk")

    SeenPeople.touch("desk", "C1", "U2", name: " ", now: @t0 + 200)
    assert [%{name: "Ana"}] = SeenPeople.list("desk")

    # A looked-up name reaches every channel the person was heard in.
    SeenPeople.touch("desk", "C2", "U2", now: @t0 + 300)
    :ok = SeenPeople.put_name("desk", "U2", "Ana Lima")
    assert ["Ana Lima", "Ana Lima"] = SeenPeople.list("desk") |> Enum.map(& &1.name)
  end

  test "the same person in two channels, or on two connections, is separate rows" do
    SeenPeople.touch("desk", "C1", "U2", now: @t0)
    SeenPeople.touch("desk", "C2", "U2", now: @t0 + 1)
    SeenPeople.touch("sales", "C1", "U2", now: @t0)

    assert ["C2", "C1"] = SeenPeople.list("desk") |> Enum.map(& &1.channel)
    assert [%{channel: "C1"}] = SeenPeople.list("desk", "C1")
    assert [%{connection: "sales"}] = SeenPeople.list("sales")
  end

  test "removing a connection forgets its people and nobody else's" do
    SeenPeople.touch("desk", "C1", "U2", now: @t0)
    SeenPeople.touch("sales", "C1", "U2", now: @t0)

    :ok = SeenPeople.delete_connection("desk")

    assert [] = SeenPeople.list("desk")
    assert [%{person: "U2"}] = SeenPeople.list("sales")
  end

  test "without the repo nothing is recorded and nothing raises" do
    stop_supervised!(Pepe.Repo)

    assert :error = SeenPeople.touch("desk", "C1", "U2", now: @t0)
    assert [] = SeenPeople.list("desk")
    assert :ok = SeenPeople.put_name("desk", "U2", "Ana")
    assert :ok = SeenPeople.delete_connection("desk")
  end

  describe "the picker's view of them" do
    test "one entry per person, with the channels they wrote in by name, most recent first" do
      Pepe.SeenChannels.touch("desk", "slack", "C1", name: "#ops", now: @t0)
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)
      SeenPeople.touch("desk", "D9", "U2", now: @t0 + 5)
      SeenPeople.touch("desk", "D9", "U3", now: @t0 + 1)

      # Channels in the order the person was last heard in them, the latest first.
      assert [
               %{id: "U2", name: "Ana", channels: ["D9", "#ops"]},
               %{id: "U3", name: nil, channels: ["D9"]}
             ] = TrainersPicker.people("desk")

      assert [%{id: "U3"}] = TrainersPicker.people("desk", "D9") |> Enum.filter(&(&1.id == "U3"))
      assert [%{id: "U2"}] = TrainersPicker.people("desk", "C1")
    end

    test "the form value round-trips every stored shape, and a stored stranger is offered as an id" do
      for list <- [nil, ["*"], [], ["U1", "U2"]] do
        assert TrainersPicker.to_list(TrainersPicker.form_value(list)) == list
      end

      assert TrainersPicker.to_list(%{"mode" => "list", "people" => ["U1"], "extra" => "<@U2>, U1, *"}) == ["U1", "U2"]
      assert TrainersPicker.to_list(%{"mode" => "list"}) == []
      assert TrainersPicker.to_list(nil) == nil

      people = [%{id: "U1", name: "Ana", channels: []}]
      assert [%{id: "U1"}, %{id: "U9", name: nil}] = TrainersPicker.with_stored(people, %{"people" => ["U1", "U9"]})
    end
  end
end
