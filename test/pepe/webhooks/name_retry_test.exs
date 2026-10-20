defmodule Pepe.Webhooks.NameRetryTest do
  @moduledoc """
  A person or channel heard before the platform let the bot read names stays an id on the
  Channels page unless the lookup is tried again. It is, while the name is missing, at most once
  every half hour for each, and never once a name is stored.
  """
  use ExUnit.Case, async: false

  alias Pepe.SeenChannels
  alias Pepe.SeenPeople
  alias Pepe.Webhooks

  defmodule FakeProvider do
    @moduledoc false
    def channel_name(_entry, channel) do
      send(Process.whereis(:name_retry_test), {:channel_lookup, channel})
      # The platform has nothing to say yet (a missing scope), so the channel stays unnamed.
      :error
    end

    def person_name(_entry, person) do
      send(Process.whereis(:name_retry_test), {:person_lookup, person})
      {:ok, "Ana"}
    end
  end

  @entry %{"slug" => "team", "provider" => "fake"}
  @t0 1_700_000_000

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    Process.register(self(), :name_retry_test)

    home = Path.join(System.tmp_dir!(), "pepe_name_retry_#{System.unique_integer([:positive])}")
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

  test "a channel still without a name is looked up again, once per window" do
    SeenChannels.touch("team", "fake", "C1", now: @t0)

    assert Webhooks.retry_channel_name(FakeProvider, @entry, "C1", @t0 + 100) == :ok
    assert_receive {:channel_lookup, "C1"}, 1_000

    Webhooks.retry_channel_name(FakeProvider, @entry, "C1", @t0 + 200)
    refute_receive {:channel_lookup, "C1"}, 200

    Webhooks.retry_channel_name(FakeProvider, @entry, "C1", @t0 + 2_000)
    assert_receive {:channel_lookup, "C1"}, 1_000
  end

  test "a channel that already has a name is never looked up again" do
    SeenChannels.touch("team", "fake", "C1", now: @t0, name: "#ops")
    Webhooks.retry_channel_name(FakeProvider, @entry, "C1", @t0 + 5_000)
    refute_receive {:channel_lookup, _}, 200
  end

  test "a person still without a name is looked up again, once per window" do
    SeenPeople.touch("team", "C1", "U1", now: @t0)

    Webhooks.retry_person_name(FakeProvider, @entry, "U1", @t0 + 100)
    assert_receive {:person_lookup, "U1"}, 1_000

    Webhooks.retry_person_name(FakeProvider, @entry, "U1", @t0 + 200)
    refute_receive {:person_lookup, "U1"}, 200
  end

  test "the name that comes back is stored for the person" do
    SeenPeople.touch("team", "C1", "U1", now: @t0)
    Webhooks.retry_person_name(FakeProvider, @entry, "U1", @t0 + 100)
    assert_receive {:person_lookup, "U1"}, 1_000

    stored = fn -> SeenPeople.get("team", "U1").name end
    assert eventually(stored, "Ana")
  end

  test "someone never heard from is not looked up" do
    Webhooks.retry_person_name(FakeProvider, @entry, "U404", @t0)
    refute_receive {:person_lookup, _}, 200
  end

  defp eventually(fun, expected, tries \\ 40) do
    cond do
      fun.() == expected ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, expected, tries - 1)
    end
  end
end
