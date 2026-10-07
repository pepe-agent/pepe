defmodule Pepe.ConfigChannelMentionTest do
  @moduledoc """
  A channel's own mention setting has three states: answers without one (`true`), requires one
  (`false`), none of its own (`nil`, the connection's default applies). Data written by the
  two-state version (only `true`, or absent) reads the same.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cfg_mention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "reads and writes all three states, and clearing removes the key" do
    assert Config.channel_mention("desk:C1") == nil

    Config.put_channel_mention("desk:C1", true)
    assert Config.channel_mention("desk:C1") == true

    Config.put_channel_mention("desk:C1", false)
    assert Config.channel_mention("desk:C1") == false
    assert Config.channel_mentions_all() == %{"desk:C1" => false}

    Config.put_channel_mention("desk:C1", nil)
    assert Config.channel_mention("desk:C1") == nil
    assert Config.channel_mentions_all() == %{}
  end

  test "the two-state read and write still work on top of it" do
    Config.put_channel_mention_optional("desk:C1", true)
    assert Config.channel_mention_optional?("desk:C1")
    assert Config.channel_mention("desk:C1") == true

    # The old "false" was a clear, not a stored "requires one".
    Config.put_channel_mention_optional("desk:C1", false)
    refute Config.channel_mention_optional?("desk:C1")
    assert Config.channel_mention("desk:C1") == nil

    Config.put_channel_mention("desk:C1", false)
    refute Config.channel_mention_optional?("desk:C1")
  end

  test "a shape no version ever wrote reads as no setting of its own" do
    Config.update(fn config -> Map.put(config, "channel_mentions", %{"desk:C1" => "yes", "desk:C2" => true, "desk:C3" => 1}) end)

    assert Config.channel_mention("desk:C1") == nil
    assert Config.channel_mention("desk:C2") == true
    assert Config.channel_mention("desk:C3") == nil
    assert Config.channel_mentions_all() == %{"desk:C2" => true}
  end
end
