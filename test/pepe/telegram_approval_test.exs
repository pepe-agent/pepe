defmodule Pepe.TelegramApprovalTest do
  @moduledoc """
  Deny-by-default user approval: a bot with `require_approval` queues unknown users instead of
  answering them; the operator approves them (from the dashboard or, via the telegram_access tool,
  by chat). Covers the config helpers and the tool.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.TelegramAccess

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_approval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_telegram(%{"name" => "default", "bot_token" => "t", "require_approval" => true, "allowed_users" => []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp user(id, name), do: %{"id" => id, "name" => name, "chat_id" => -100, "at" => 0, "sample" => "oi"}

  describe "config helpers" do
    test "require_approval? reflects the flag" do
      assert Config.telegram_require_approval?("default")
      Config.update_telegram_bot("default", &Map.put(&1, "require_approval", false))
      refute Config.telegram_require_approval?("default")
    end

    test "add queues a blocked user once; approve moves them to allowed_users; dismiss just drops them" do
      Config.add_telegram_pending("default", user(1, "Salvador"))
      Config.add_telegram_pending("default", user(1, "Salvador"))
      Config.add_telegram_pending("default", user(2, "Ana"))

      assert Enum.map(Config.telegram_pending("default"), & &1["id"]) == [1, 2]

      assert :ok = Config.approve_telegram_user("default", 1)
      assert Config.telegram_bot("default")["allowed_users"] == [1]
      assert Enum.map(Config.telegram_pending("default"), & &1["id"]) == [2]

      assert :ok = Config.dismiss_telegram_pending("default", 2)
      assert Config.telegram_pending("default") == []
      # dismiss does NOT allow them
      refute 2 in (Config.telegram_bot("default")["allowed_users"] || [])
    end

    test "an already-allowed user is not re-queued" do
      Config.update_telegram_bot("default", &Map.put(&1, "allowed_users", [5]))
      Config.add_telegram_pending("default", user(5, "known"))
      assert Config.telegram_pending("default") == []
    end

    test "approving captures the name; telegram_allowed/1 lists it; revoke removes it and the name" do
      Config.add_telegram_pending("default", user(1, "Salvador"))
      Config.approve_telegram_user("default", 1)

      assert Config.telegram_allowed("default") == [%{"id" => 1, "name" => "Salvador"}]

      assert :ok = Config.revoke_telegram_user("default", 1)
      assert Config.telegram_bot("default")["allowed_users"] == []
      assert Config.telegram_allowed("default") == []
      # the name is dropped too, not left as an orphan entry
      assert Config.telegram_bot("default")["allowed_users_names"] == %{}
    end

    test "an id added by hand (no queue history) has no name on record, but still lists and revokes" do
      Config.update_telegram_bot("default", &Map.put(&1, "allowed_users", [4242]))

      assert Config.telegram_allowed("default") == [%{"id" => 4242, "name" => nil}]

      assert :ok = Config.revoke_telegram_user("default", 4242)
      assert Config.telegram_allowed("default") == []
    end

    test "revoking a user does not disturb another approved user" do
      Config.add_telegram_pending("default", user(1, "Salvador"))
      Config.add_telegram_pending("default", user(2, "Ana"))
      Config.approve_telegram_user("default", 1)
      Config.approve_telegram_user("default", 2)

      Config.revoke_telegram_user("default", 1)

      assert Config.telegram_allowed("default") == [%{"id" => 2, "name" => "Ana"}]
    end
  end

  describe "telegram_access tool" do
    @ctx %{session_key: "telegram:-100"}

    test "list reports the queue; approve and dismiss act on ids" do
      Config.add_telegram_pending("default", user(1, "Salvador"))
      Config.add_telegram_pending("default", user(2, "Ana"))

      assert {:ok, listing} = TelegramAccess.run(%{"action" => "list"}, @ctx)
      assert listing =~ "Salvador (id 1)"
      assert listing =~ "Ana (id 2)"

      assert {:ok, _} = TelegramAccess.run(%{"action" => "approve", "user_ids" => [1]}, @ctx)
      assert Config.telegram_bot("default")["allowed_users"] == [1]

      assert {:ok, _} = TelegramAccess.run(%{"action" => "dismiss", "user_ids" => [2]}, @ctx)
      assert Config.telegram_pending("default") == []
    end

    test "empty queue and missing/invalid input are handled" do
      assert {:ok, "No users are waiting for approval."} = TelegramAccess.run(%{"action" => "list"}, @ctx)
      assert {:error, _} = TelegramAccess.run(%{"action" => "approve"}, @ctx)
      assert {:error, _} = TelegramAccess.run(%{"action" => "list"}, %{session_key: "web:1"})
    end
  end
end
