defmodule Mix.Tasks.PepeDbCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dbcli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "list says so when nothing is configured" do
    assert pepe(["db", "list"]) =~ "no database connections"
  end

  test "add saves an unscoped connection; list shows it" do
    out = pepe(["db", "add", "plain_pg", "--host", "h", "--database", "d", "--user", "u", "--password", "${PW}"])
    assert out =~ "saved"

    cfg = Config.db_connection("plain_pg")
    assert cfg.engine == "postgres"
    assert cfg.host == "h"
    assert cfg.port == 5432
    assert cfg.tenant_column == nil

    assert pepe(["db", "list"]) =~ "unscoped"
  end

  test "add with --tenant-column fixed mode saves the binding; list shows it's scoped" do
    pepe([
      "db",
      "add",
      "billing_pg",
      "--host",
      "h",
      "--database",
      "d",
      "--user",
      "u",
      "--password",
      "${PW}",
      "--tenant-column",
      "company_id",
      "--tenant-mode",
      "fixed",
      "--tenant-value",
      "acme-inc"
    ])

    cfg = Config.db_connection("billing_pg")
    assert cfg.tenant_column == "company_id"
    assert cfg.tenant_binding == %{"mode" => "fixed", "value" => "acme-inc"}

    assert pepe(["db", "list"]) =~ "tenant-scoped on company_id"
  end

  test "add with --tenant-column but no --tenant-mode/--tenant-value is refused" do
    err =
      pepe_err(["db", "add", "bad", "--host", "h", "--database", "d", "--user", "u", "--password", "p", "--tenant-column", "company_id"])

    assert err =~ "tenant-mode"
    assert Config.db_connection("bad") == nil
  end

  test "add with an invalid --tenant-mode is refused" do
    err =
      pepe_err([
        "db",
        "add",
        "bad",
        "--host",
        "h",
        "--database",
        "d",
        "--user",
        "u",
        "--password",
        "p",
        "--tenant-column",
        "c",
        "--tenant-mode",
        "nope",
        "--tenant-value",
        "x"
      ])

    assert err =~ ~s(--tenant-mode)
    assert Config.db_connection("bad") == nil
  end

  test "add with agent_field mode requires tenant-value to be project or bare" do
    err =
      pepe_err([
        "db",
        "add",
        "bad",
        "--host",
        "h",
        "--database",
        "d",
        "--user",
        "u",
        "--password",
        "p",
        "--tenant-column",
        "c",
        "--tenant-mode",
        "agent_field",
        "--tenant-value",
        "whatever"
      ])

    assert err =~ "project"
    assert Config.db_connection("bad") == nil
  end

  test "add reports a raw (non-${VAR}) password so it can be rotated" do
    out = pepe(["db", "add", "leaky", "--host", "h", "--database", "d", "--user", "u", "--password", "sk-live-1234567890abcdef123456"])
    assert out =~ "leaky"
  end

  test "add with an ${ENV_VAR} password prints no secrets warning" do
    out = pepe(["db", "add", "clean", "--host", "h", "--database", "d", "--user", "u", "--password", "${DB_PW}"])
    refute out =~ "typed"
  end

  test "remove deletes a configured connection; remove of an unknown name errors" do
    pepe(["db", "add", "gone", "--host", "h", "--database", "d", "--user", "u", "--password", "p"])
    assert pepe(["db", "remove", "gone"]) =~ "removed"
    assert Config.db_connection("gone") == nil

    assert pepe_err(["db", "remove", "gone"]) =~ "unknown database connection"
  end

  test "add without required flags is refused" do
    assert pepe_err(["db", "add", "incomplete", "--host", "h"]) =~ "--database"
  end
end
