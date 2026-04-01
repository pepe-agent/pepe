defmodule Pepe.Tools.ManagePepeTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.ManagePepe

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_mp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"agents" => %{}}))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx, do: %{agent: %Agent{name: "owner"}}

  test "runs a real CLI command and returns its captured output" do
    assert {:ok, out} = ManagePepe.run(%{"command" => "agent list"}, ctx())
    assert is_binary(out)
    refute out =~ "\e["
  end

  test "a command that changes config actually takes effect" do
    args = %{"command" => ~s(agent add helper --prompt "you help" --tools read_file)}
    assert {:ok, _out} = ManagePepe.run(args, ctx())
    assert Config.get_agent("helper")
  end

  test "a leading \"pepe\" in the command is tolerated" do
    assert {:ok, _out} = ManagePepe.run(%{"command" => "pepe agent list"}, ctx())
  end

  for blocked <- ~w(setup chat tui serve eval) do
    test "refuses the interactive/blocking command #{blocked}" do
      assert {:error, msg} = ManagePepe.run(%{"command" => unquote(blocked)}, ctx())
      assert msg =~ "can't be run by chat"
    end
  end

  test "refuses a foreground gateway" do
    assert {:error, msg} = ManagePepe.run(%{"command" => "gateway telegram"}, ctx())
    assert msg =~ "can't be run by chat"
  end

  test "allows a non-interactive gateway subcommand" do
    assert {:ok, _out} = ManagePepe.run(%{"command" => "gateway telegram list"}, ctx())
  end

  test "restores the persist_sessions app env after a with_app command" do
    Application.put_env(:pepe, :persist_sessions, true)
    assert {:ok, _} = ManagePepe.run(%{"command" => "doctor"}, ctx())
    assert Application.get_env(:pepe, :persist_sessions) == true
  end

  test "without a calling agent it refuses" do
    assert {:error, _} = ManagePepe.run(%{"command" => "agent list"}, %{})
  end
end
