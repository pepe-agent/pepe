defmodule Pepe.LabelsTest do
  @moduledoc """
  A label is what the operator calls a connection, a channel or a person. It wins over the
  provider's name, which wins over the id; it survives every refresh; it is display only.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Labels
  alias Pepe.SeenChannels
  alias Pepe.SeenPeople

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_labels_#{System.unique_integer([:positive])}")
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

  test "a label is trimmed, capped at 60 characters, and blank clears it" do
    assert Labels.clean("  Ops team ") == "Ops team"
    assert Labels.clean("   ") == nil
    assert Labels.clean(nil) == nil
    assert Labels.clean(String.duplicate("x", 80)) == String.duplicate("x", 60)
  end

  describe "a channel" do
    test "the label beats the provider's name, which beats the id, and clearing falls back" do
      SeenChannels.touch("desk", "slack", "C1", now: @t0)
      assert %{text: "C1", label: nil} = Labels.channel("desk", "C1")

      SeenChannels.touch("desk", "slack", "C1", name: "#ops", now: @t0 + 100)
      assert %{text: "#ops"} = Labels.channel("desk", "C1")

      SeenChannels.put_label("desk", "C1", " Operations ")
      assert %{text: "Operations", label: "Operations", id: "C1"} = Labels.channel("desk", "C1")

      SeenChannels.put_label("desk", "C1", "")
      assert %{text: "#ops", label: nil} = Labels.channel("desk", "C1")
    end

    test "the label survives later messages and a provider name refresh" do
      SeenChannels.touch("desk", "slack", "C1", now: @t0)
      SeenChannels.put_label("desk", "C1", "Operations")

      SeenChannels.touch("desk", "slack", "C1", name: "#ops-renamed", now: @t0 + 100)
      SeenChannels.put_name("desk", "C1", "#ops-again")

      assert %{text: "Operations"} = Labels.channel("desk", "C1")
      assert [%{name: "#ops-again", label: "Operations"}] = SeenChannels.list("desk")
    end

    test "is per connection, and a channel never heard from is just its id" do
      SeenChannels.touch("desk", "slack", "C1", now: @t0)
      SeenChannels.touch("sales", "slack", "C1", now: @t0)
      SeenChannels.put_label("desk", "C1", "Operations")

      assert %{text: "Operations"} = Labels.channel("desk", "C1")
      assert %{text: "C1"} = Labels.channel("sales", "C1")
      assert %{text: "C9", label: nil} = Labels.channel("desk", "C9")
    end
  end

  describe "a person" do
    test "the label follows the person across the connection's channels, including ones heard later" do
      SeenPeople.touch("desk", "C1", "U2", name: "ana", now: @t0)
      SeenPeople.touch("desk", "C2", "U2", now: @t0)
      SeenPeople.put_label("desk", "U2", "Ana Lima")

      assert ["Ana Lima", "Ana Lima"] = SeenPeople.list("desk") |> Enum.map(& &1.label)
      assert %{text: "Ana Lima", label: "Ana Lima"} = Labels.person("desk", "U2")

      SeenPeople.touch("desk", "C3", "U2", now: @t0 + 1)
      assert %{label: "Ana Lima"} = SeenPeople.list("desk", "C3") |> hd()

      # A refreshed provider name never overwrites it; clearing falls back to that name.
      SeenPeople.touch("desk", "C1", "U2", name: "ana.lima", now: @t0 + 100)
      assert %{text: "Ana Lima"} = Labels.person("desk", "U2")
      SeenPeople.put_label("desk", "U2", nil)
      assert %{text: "ana.lima", label: nil} = Labels.person("desk", "U2")
    end

    test "is per connection, and an unknown person is just the id" do
      SeenPeople.touch("desk", "C1", "U2", now: @t0)
      SeenPeople.touch("sales", "C1", "U2", now: @t0)
      SeenPeople.put_label("desk", "U2", "Ana")

      assert %{text: "Ana"} = Labels.person("desk", "U2")
      assert %{text: "U2"} = Labels.person("sales", "U2")
      assert %{text: "U9"} = Labels.person("desk", "U9")
    end
  end

  describe "a connection" do
    test "reads its label off the webhook entry or the bot, else is its slug" do
      Config.put_webhook("desk", %{"provider" => "slack", "agent" => "a", "label" => "Support Slack"})
      Config.put_telegram_bot("sales", %{"bot_token" => "${T}", "label" => "Sales bot"})

      assert %{text: "Support Slack", id: "desk"} = Labels.connection("desk")
      assert %{text: "Sales bot", id: "sales"} = Labels.connection("sales")
      assert %{text: "default", label: nil} = Labels.connection("default")
      assert %{text: "nope"} = Labels.connection("nope")
      assert %{text: "Other"} = Labels.connection("desk", %{"label" => "Other"})
    end
  end

  describe "a Telegram session key" do
    test "reads as the bot and the chat by name once either is named, else stays the key" do
      assert Labels.session("telegram:-1001") == "telegram:-1001"
      assert Labels.session("api:abc") == "api:abc"

      SeenChannels.touch("default", "telegram", "-1001", kind: "group", name: "Ops team", now: @t0)
      assert Labels.session("telegram:-1001") == "default: Ops team"
      assert PepeWeb.DashData.deliver_label("telegram:-1001") == "default: Ops team"
      assert PepeWeb.DashData.deliver_label("telegram:55") == "Telegram 55"

      Config.put_telegram_bot("sales", %{"bot_token" => "${T}", "label" => "Sales bot"})
      SeenChannels.touch("sales", "telegram", "77#t3", kind: "group", now: @t0)
      SeenChannels.put_label("sales", "77#t3", "Leads topic")
      assert Labels.session("telegram:sales:77#t3") == "Sales bot: Leads topic"
    end
  end
end
