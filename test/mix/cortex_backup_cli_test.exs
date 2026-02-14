defmodule Mix.Tasks.CortexBackupCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_bk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "data/mnesia"))
    File.mkdir_p!(Path.join(home, "agents/zak"))

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"telegram" => %{"bot_token" => "${TEST_BOT_TOKEN}"}})
    )

    File.write!(Path.join(home, "agents/zak/SOUL.md"), "I am Zak.")
    File.write!(Path.join(home, "data/mnesia/schema.DAT"), "junk")

    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)
    out = Path.join(System.tmp_dir!(), "bk_#{System.unique_integer([:positive])}.tgz")

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
      File.rm(out)
    end)

    {:ok, out: out}
  end

  test "backup archives the durable files, skips mnesia, and lists secret env vars", %{out: out} do
    output = capture_io(fn -> Mix.Tasks.Cortex.dispatch(["backup", "--output", out]) end)

    assert File.exists?(out)
    assert output =~ "TEST_BOT_TOKEN"
    assert output =~ "UNSET"

    entries = System.cmd("tar", ["tzf", out]) |> elem(0)
    assert entries =~ "config.json"
    assert entries =~ "agents/zak/SOUL.md"
    refute entries =~ "mnesia"
  end
end
