defmodule Mix.Tasks.PepeGatewayTelegramCliTest do
  @moduledoc """
  `mix pepe gateway telegram add`: an invalid `--progress` used to be silently dropped
  (`valid_progress/1` returns `nil` for a typo, and the config map just filters `nil`
  values out - no error, the bot got created without `tool_progress` set, and nothing
  told the operator their flag was wrong). Caught by CodeRabbit reviewing the same PR
  that added `--commands`/`--no-commands` next to it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_gw_tg_cli_#{System.unique_integer([:positive])}")
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
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  describe "telegram add" do
    test "an unsupported --progress value is refused, not silently dropped" do
      err = pepe_err(["gateway", "telegram", "add", "sales", "--token", "t", "--progress", "verbse"])
      assert err =~ "--progress must be one of"
      refute Config.telegram_bot("sales")
    end

    test "a valid --progress value is stored" do
      pepe(["gateway", "telegram", "add", "sales", "--token", "t", "--progress", "ambient"])
      assert Config.telegram_bot("sales")["tool_progress"] == "ambient"
    end

    test "--no-commands stores commands: false" do
      pepe(["gateway", "telegram", "add", "sales", "--token", "t", "--no-commands"])
      assert Config.telegram_bot("sales")["commands"] == false
    end

    test "omitting --commands leaves it unset" do
      pepe(["gateway", "telegram", "add", "sales", "--token", "t"])
      refute Map.has_key?(Config.telegram_bot("sales"), "commands")
    end
  end
end
