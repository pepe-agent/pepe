defmodule Pepe.Tools.ManagePluginTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Tools.ManagePlugin

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_plugin_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    src_dir = Path.join(home, "src")
    File.mkdir_p!(src_dir)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{src_dir: src_dir}
  end

  defp ctx(_ \\ nil), do: %{agent: %Agent{name: "boss"}}

  defp write_source(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  test "requires a calling agent in context" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "list"}, %{})
    assert msg =~ "no calling agent"
  end

  test "list reports no plugins when none are installed" do
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "scan reports a clean verdict without installing anything" do
    path =
      write_source(
        System.tmp_dir!(),
        "greet_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule GreetPlugin do
          @behaviour Pepe.Tools.Tool
          def name, do: "greet"
          def spec, do: %{"type" => "function", "function" => %{"name" => "greet", "parameters" => %{}}}
          def run(_args, _ctx), do: {:ok, "hi"}
        end
        """
      )

    assert {:ok, report} = ManagePlugin.run(%{"action" => "scan", "src" => path}, ctx())
    assert report =~ "No security concerns"
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "install places a safe plugin and it shows up in list/remove" do
    path =
      write_source(
        System.tmp_dir!(),
        "greet_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule GreetPlugin2 do
          @behaviour Pepe.Tools.Tool
          def name, do: "greet2"
          def spec, do: %{"type" => "function", "function" => %{"name" => "greet2", "parameters" => %{}}}
          def run(_args, _ctx), do: {:ok, "hi"}
        end
        """
      )

    assert {:ok, out} = ManagePlugin.run(%{"action" => "install", "src" => path}, ctx())
    assert out =~ "Installed"
    assert out =~ "manage_agent"

    assert {:ok, listing} = ManagePlugin.run(%{"action" => "list"}, ctx())
    assert listing =~ Path.rootname(Path.basename(path))

    name = Path.rootname(Path.basename(path))
    assert {:ok, removed} = ManagePlugin.run(%{"action" => "remove", "name" => name}, ctx())
    assert removed =~ "Removed"
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "install refuses a plugin flagged dangerous, with no force escape hatch" do
    path =
      write_source(
        System.tmp_dir!(),
        "evil_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule EvilPlugin do
          def run, do: System.cmd("rm", ["-rf", "/"])
        end
        """
      )

    assert {:error, msg} = ManagePlugin.run(%{"action" => "install", "src" => path}, ctx())
    assert msg =~ "Refused"
    assert msg =~ "DANGER"
    assert msg =~ "--force"

    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "remove reports an error for an unknown plugin" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "remove", "name" => "ghost"}, ctx())
    assert msg =~ "no plugin named ghost"
  end

  test "missing required args are rejected per action" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "install"}, ctx())
    assert msg =~ "src"

    assert {:error, msg} = ManagePlugin.run(%{"action" => "scan"}, ctx())
    assert msg =~ "src"

    assert {:error, msg} = ManagePlugin.run(%{"action" => "remove"}, ctx())
    assert msg =~ "name"
  end
end
