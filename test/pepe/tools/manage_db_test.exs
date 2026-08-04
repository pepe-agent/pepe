defmodule Pepe.Tools.ManageDbTest do
  @moduledoc "The db_connections surface an agent actually reaches, from a conversation."
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.ManageDb

  @ctx [agent: "ops"]

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mdb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "adds an unscoped connection" do
    assert {:ok, out} =
             ManageDb.run(
               %{"action" => "add", "name" => "plain", "host" => "h", "database" => "d", "user" => "u", "password" => "${PW}"},
               @ctx
             )

    assert out =~ "saved"
    assert Config.db_connection("plain").tenant_column == nil
  end

  test "adds a fixed-mode tenant-scoped connection" do
    assert {:ok, _} =
             ManageDb.run(
               %{
                 "action" => "add",
                 "name" => "billing",
                 "host" => "h",
                 "database" => "d",
                 "user" => "u",
                 "password" => "${PW}",
                 "tenant_column" => "company_id",
                 "tenant_mode" => "fixed",
                 "tenant_value" => "acme-inc"
               },
               @ctx
             )

    cfg = Config.db_connection("billing")
    assert cfg.tenant_column == "company_id"
    assert cfg.tenant_binding == %{"mode" => "fixed", "value" => "acme-inc"}
  end

  test "a connection missing required fields is refused, not half-saved" do
    assert {:error, message} = ManageDb.run(%{"action" => "add", "name" => "incomplete", "host" => "h"}, @ctx)
    assert message =~ "database"
    assert Config.db_connection("incomplete") == nil
  end

  test "tenant_column with no tenant_mode/tenant_value is refused" do
    assert {:error, message} =
             ManageDb.run(
               %{
                 "action" => "add",
                 "name" => "bad",
                 "host" => "h",
                 "database" => "d",
                 "user" => "u",
                 "password" => "p",
                 "tenant_column" => "c"
               },
               @ctx
             )

    assert message =~ "tenant_mode"
    assert Config.db_connection("bad") == nil
  end

  test "agent_field mode requires tenant_value to be project or bare" do
    assert {:error, message} =
             ManageDb.run(
               %{
                 "action" => "add",
                 "name" => "bad",
                 "host" => "h",
                 "database" => "d",
                 "user" => "u",
                 "password" => "p",
                 "tenant_column" => "c",
                 "tenant_mode" => "agent_field",
                 "tenant_value" => "whatever"
               },
               @ctx
             )

    assert message =~ "project"
    assert Config.db_connection("bad") == nil
  end

  test "a raw password is saved and reported, not silently swallowed" do
    assert {:ok, out} =
             ManageDb.run(
               %{
                 "action" => "add",
                 "name" => "leaky",
                 "host" => "h",
                 "database" => "d",
                 "user" => "u",
                 "password" => "sk-live-abcdefghijklmnopqrstuvwxyz0123456789"
               },
               @ctx
             )

    assert out =~ "saved"
    assert out =~ ~r/revoke|reissue|compromised/i
    assert Config.db_connection("leaky"), "the connection is still saved - refusing would not un-leak it"
  end

  test "list reports scoped vs unscoped connections" do
    ManageDb.run(%{"action" => "add", "name" => "plain", "host" => "h", "database" => "d", "user" => "u", "password" => "p"}, @ctx)

    ManageDb.run(
      %{
        "action" => "add",
        "name" => "scoped",
        "host" => "h",
        "database" => "d",
        "user" => "u",
        "password" => "p",
        "tenant_column" => "company_id",
        "tenant_mode" => "fixed",
        "tenant_value" => "x"
      },
      @ctx
    )

    assert {:ok, out} = ManageDb.run(%{"action" => "list"}, @ctx)
    assert out =~ "plain: unscoped"
    assert out =~ "scoped: tenant-scoped on company_id"
  end

  test "remove deletes a configured connection; removing an unknown name errors" do
    ManageDb.run(%{"action" => "add", "name" => "gone", "host" => "h", "database" => "d", "user" => "u", "password" => "p"}, @ctx)
    assert {:ok, out} = ManageDb.run(%{"action" => "remove", "name" => "gone"}, @ctx)
    assert out =~ "removed"
    assert Config.db_connection("gone") == nil

    assert {:error, message} = ManageDb.run(%{"action" => "remove", "name" => "gone"}, @ctx)
    assert message =~ "no database connection"
  end

  test "no calling agent in context is refused" do
    assert {:error, message} = ManageDb.run(%{"action" => "list"}, [])
    assert message =~ "no calling agent"
  end

  test "the declared schema covers every field the code reads" do
    props = ManageDb.spec()["function"]["parameters"]["properties"]

    for field <- ~w(action name host port database user password tenant_column tenant_mode tenant_value) do
      assert Map.has_key?(props, field), "#{field} is read by the tool but not declared"
    end
  end
end
