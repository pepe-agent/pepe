defmodule Mix.Tasks.PepeDashboardPasswordCliTest do
  @moduledoc """
  `pepe dashboard password '<literal>'` hashes before writing to config.json; a
  reference to a secret kept outside the file (`${ENV_VAR}`, `exec:`, `file:`) has
  nothing to hash and is stored verbatim. Pins the exact boundary between those two
  cases against `Pepe.Config.interpolate/1`'s own matching rules, since the two
  disagreeing (a reference treated as literal, or vice versa) either hashes a
  reference into uselessness or leaves a real password in plain text, the two
  regressions this file exists to catch.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dashboard_pw_cli_#{System.unique_integer([:positive])}")
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

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp raw_password, do: get_in(Config.load(), ["dashboard", "password"])

  test "a literal password is hashed, never stored in the clear" do
    pepe(["dashboard", "password", "s3cret"])

    stored = raw_password()
    refute stored == "s3cret"
    assert Config.dashboard_password_hashed?(stored)
    assert Bcrypt.verify_pass("s3cret", stored)
  end

  test "an uppercase ${ENV_VAR} reference is stored verbatim, not hashed" do
    pepe(["dashboard", "password", "${PEPE_DASHBOARD_PASSWORD}"])
    assert raw_password() == "${PEPE_DASHBOARD_PASSWORD}"
  end

  test "a lowercase ${my_pw} is NOT a reference interpolate/1 resolves, so it must be hashed too" do
    pepe(["dashboard", "password", "${my_pw}"])

    stored = raw_password()
    refute stored == "${my_pw}"
    assert Config.dashboard_password_hashed?(stored)
  end

  test "a vault exec: reference is stored verbatim, not hashed" do
    pepe(["dashboard", "password", "exec:echo hi"])
    assert raw_password() == "exec:echo hi"
  end

  test "a vault file: reference is stored verbatim, not hashed" do
    pepe(["dashboard", "password", "file:/run/secrets/dashboard_pw"])
    assert raw_password() == "file:/run/secrets/dashboard_pw"
  end

  test "--clear removes it" do
    pepe(["dashboard", "password", "s3cret"])
    pepe(["dashboard", "password", "--clear"])
    assert raw_password() == nil
  end
end
