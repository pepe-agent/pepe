defmodule Pepe.MessageLimitTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Usage

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_msglimit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.add_project("acme", %{"message_limit" => 3})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "project_message_limit reads the cap; root and unset projects have none" do
    assert Config.project_message_limit("acme") == 3
    assert Config.project_message_limit(nil) == nil
    assert Config.project_message_limit("nope") == nil
  end

  test "a non-positive or non-integer message_limit is treated as unset" do
    Config.add_project("weird", %{"message_limit" => 0})
    Config.add_project("weirder", %{"message_limit" => -5})
    Config.add_project("weirdest", %{"message_limit" => "not a number"})

    assert Config.project_message_limit("weird") == nil
    assert Config.project_message_limit("weirder") == nil
    assert Config.project_message_limit("weirdest") == nil
  end

  test "record_message and message_count_month_to_date round-trip" do
    assert Usage.message_count_month_to_date("acme") == 0

    Usage.record_message("acme")
    Usage.record_message("acme")

    assert Usage.message_count_month_to_date("acme") == 2
    # A different project's counter is independent.
    assert Usage.message_count_month_to_date("other") == 0
  end

  test "recording against root (nil project) counts toward its own counter" do
    Usage.record_message(nil)
    Usage.record_message(nil)
    assert Usage.message_count_month_to_date(nil) == 2
    # A project's counter is unaffected by root's.
    assert Usage.message_count_month_to_date("acme") == 0
  end

  test "root can have its own message-count cap, independent of any project's" do
    Config.update_scope(nil, %{"message_limit" => 2})
    assert Config.project_message_limit(nil) == 2

    refute Usage.over_message_limit?(nil)
    Usage.record_message(nil)
    Usage.record_message(nil)
    assert Usage.over_message_limit?(nil)

    Usage.reset_messages(nil)
    refute Usage.over_message_limit?(nil)
  end

  test "over_message_limit? is false under the cap and true once it's reached" do
    refute Usage.over_message_limit?("acme")

    Usage.record_message("acme")
    Usage.record_message("acme")
    refute Usage.over_message_limit?("acme")

    Usage.record_message("acme")
    assert Usage.over_message_limit?("acme")
  end

  test "a project with no cap is never over the message limit" do
    Config.add_project("free", %{})
    for _ <- 1..50, do: Usage.record_message("free")
    refute Usage.over_message_limit?("free")
  end

  test "root is never over the message limit" do
    for _ <- 1..50, do: Usage.record_message(nil)
    refute Usage.over_message_limit?(nil)
  end

  test "reset_messages zeroes the counter without touching the ledger's audit trail" do
    Usage.record_message("acme")
    Usage.record_message("acme")
    Usage.record_message("acme")
    assert Usage.over_message_limit?("acme")

    Usage.reset_messages("acme")
    assert Usage.message_count_month_to_date("acme") == 0
    refute Usage.over_message_limit?("acme")

    # Messages recorded before the reset still exist in the ledger (audit trail).
    entries = Pepe.Repo.all(Pepe.Usage.MessageEvent)
    assert Enum.count(entries, &(&1.project == "acme" and not &1.reset)) == 3
  end

  test "only messages recorded after a reset count toward the cap again" do
    Usage.record_message("acme")
    Usage.reset_messages("acme")
    Usage.record_message("acme")
    Usage.record_message("acme")

    assert Usage.message_count_month_to_date("acme") == 2
  end

  test "resetting can be done multiple times in the same month" do
    Usage.record_message("acme")
    Usage.reset_messages("acme")
    Usage.record_message("acme")
    Usage.reset_messages("acme")
    Usage.record_message("acme")

    assert Usage.message_count_month_to_date("acme") == 1
  end

  test "resetting a project with no messages yet is harmless" do
    Usage.reset_messages("acme")
    assert Usage.message_count_month_to_date("acme") == 0
  end

  test "resetting root (nil project) is a no-op" do
    Usage.reset_messages(nil)
    assert Usage.message_count_month_to_date(nil) == 0
  end

  test "messages_reset_at is nil until a reset happens, then reflects it" do
    assert Usage.messages_reset_at("acme") == nil
    Usage.reset_messages("acme")
    assert_in_delta Usage.messages_reset_at("acme"), System.system_time(:second), 2
  end
end
