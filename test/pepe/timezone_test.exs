defmodule Pepe.TimezoneTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias PepeWeb.DashData

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "default_timezone falls back to UTC and is settable" do
    assert Config.default_timezone() == "Etc/UTC"
    Config.set_default_timezone("America/Sao_Paulo")
    assert Config.default_timezone() == "America/Sao_Paulo"
  end

  test "local_datetime shows the configured timezone, not UTC" do
    Config.set_default_timezone("America/Sao_Paulo")
    {:ok, utc} = DateTime.new(~D[2026-07-06], ~T[15:00:00], "Etc/UTC")
    ts = DateTime.to_unix(utc)

    # America/Sao_Paulo is UTC-3 (no DST), so 15:00 UTC is 12:00 local.
    assert DashData.local_datetime(ts, "%H:%M") == "12:00"
  end

  test "the agent's system prompt grounds it in local time" do
    Config.set_default_timezone("America/Sao_Paulo")
    sp = Workspace.system_prompt(%{name: "bot", system_prompt: "hi"})

    assert sp =~ "Current time"
    assert sp =~ "America/Sao_Paulo"
    assert sp =~ "Do not assume UTC"
  end
end
