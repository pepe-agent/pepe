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
end
