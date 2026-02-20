defmodule Pepe.Tools.RunScriptTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Tools.RunScript

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_runscript_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "runs an elixir script and returns its output (elixir is always available)" do
    {:ok, out} = RunScript.run(%{"language" => "elixir", "code" => "IO.puts(2 + 3)"}, %{})
    assert out =~ "exit 0"
    assert out =~ "5"
  end

  test "captures a non-zero exit and stderr" do
    {:ok, out} = RunScript.run(%{"language" => "bash", "code" => "echo oops >&2; exit 7"}, %{})
    assert out =~ "exit 7"
    assert out =~ "oops"
  end

  test "rejects an unknown language" do
    assert {:error, msg} = RunScript.run(%{"language" => "cobol", "code" => "x"}, %{})
    assert msg =~ "unsupported"
  end

  test "re-runs a saved script by file path, inferring language from the extension" do
    dir = Workspace.dir("zak")
    File.mkdir_p!(Path.join(dir, "scripts"))
    File.write!(Path.join(dir, "scripts/hello.exs"), ~s|IO.puts("hi from a saved file")|)

    {:ok, out} = RunScript.run(%{"file" => "scripts/hello.exs"}, %{agent: %{name: "zak"}})
    assert out =~ "hi from a saved file"
  end

  test "passes args to the program" do
    {:ok, out} =
      RunScript.run(
        %{"language" => "bash", "code" => "echo \"$1-$2\"", "args" => ["a", "b"]},
        %{}
      )

    assert out =~ "a-b"
  end
end
