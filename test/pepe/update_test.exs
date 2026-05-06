defmodule Pepe.UpdateTest do
  use ExUnit.Case, async: true

  alias Pepe.Update

  test "target names the right release asset for this OS/arch" do
    assert Update.target() in [
             "pepe_macos_arm",
             "pepe_macos_x86",
             "pepe_linux_arm",
             "pepe_linux_x86",
             "pepe_windows.exe"
           ]
  end

  test "newer? compares semver versions" do
    assert Update.newer?("9.9.9", "0.1.0")
    refute Update.newer?("0.1.0", "0.2.0")
    refute Update.newer?("0.2.0", "0.2.0")
  end

  test "current returns the running version string" do
    assert Update.current() =~ ~r/^\d+\.\d+/
  end

  test "running from a source checkout is detected (Mix is present in tests)" do
    assert Update.running_from_source?()
  end

  test "binary_path returns an absolute path" do
    assert Update.binary_path() |> Path.type() == :absolute
  end

  describe "pepe version" do
    test "answers under each of its three names, with no config and no network" do
      for argv <- [["version"], ["--version"], ["-v"]] do
        out = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)

        assert out =~ "pepe #{Update.current()}"
      end
    end

    test "says which build it is, so a bug report carries it" do
      out = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Pepe.dispatch(["version"]) end)

      # A source checkout is what the suite runs as; the packaged binary prints its target
      # instead. Either way the line has to be there: "0.3.0" alone does not tell you
      # whether "it won't start" means the arm build or the x86 one.
      assert out =~ "source checkout" or out =~ Update.target()
    end
  end
end
