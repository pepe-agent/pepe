defmodule Mix.Tasks.PepeGatewayMentionCliTest do
  @moduledoc """
  `mix pepe gateway mention SLUG ...`: the connection's default for whether its channels
  answer without an @mention, and one channel's own answer, which wins over the default.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_mention_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_webhook("desk", %{"provider" => "slack", "agent" => "support", "mode" => "admin", "config" => %{"bot_token" => "${T}"}})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "shows the connection's default and every channel with an answer of its own" do
    out = pepe(["gateway", "mention", "desk"])
    assert out =~ "desk: a mention is required (the connection's default)"
    refute out =~ "(own)"

    Config.put_channel_mention("desk:C1", true)
    Config.put_channel_mention("desk:C2", false)
    out = pepe(["gateway", "mention", "desk"])
    assert out =~ "C1: answers without a mention (own)"
    assert out =~ "C2: a mention is required (own)"
  end

  test "--set changes the connection's default, stored only when it differs from required" do
    out = pepe(["gateway", "mention", "desk", "--set", "optional"])
    assert out =~ "desk: answers without a mention in every channel"
    assert Config.get_webhook("desk")["mention_optional"] == true

    pepe(["gateway", "mention", "desk", "--set", "required"])
    refute Map.has_key?(Config.get_webhook("desk"), "mention_optional")
  end

  test "--channel sets one channel's own answer, in either direction, and --default drops it" do
    out = pepe(["gateway", "mention", "desk", "--channel", "C1", "--set", "required"])
    assert out =~ "C1: a mention is required (this channel's own setting)"
    assert Config.channel_mention("desk:C1") == false

    pepe(["gateway", "mention", "desk", "--channel", "C1", "--set", "optional"])
    assert Config.channel_mention("desk:C1") == true

    out = pepe(["gateway", "mention", "desk", "--channel", "C1", "--default"])
    assert out =~ "C1 follows the connection again: a mention is required"
    assert Config.channel_mention("desk:C1") == nil
  end

  test "a value other than optional or required, or an unknown connection, is refused" do
    assert pepe_err(["gateway", "mention", "desk", "--set", "sometimes"]) =~ "--set must be optional"
    refute Map.has_key?(Config.get_webhook("desk"), "mention_optional")

    assert pepe_err(["gateway", "mention", "nope"]) =~ "no connection named nope"
  end
end
