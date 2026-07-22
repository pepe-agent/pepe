defmodule Mix.Tasks.PepeBrowserCliTest do
  @moduledoc """
  `mix pepe browser install` - detects the host's Linux package manager and installs
  a browser through it for real (the `browser` agent tool can then drive it).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  defp fake_executable!(dir, name, script) do
    path = Path.join(dir, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp with_fake_path(dir) do
    prev_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> prev_path)
    on_exit(fn -> System.put_env("PATH", prev_path) end)
  end

  test "with a detected package manager, runs the real install command" do
    dir = Path.join(System.tmp_dir!(), "pepe_browser_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")
    fake_executable!(dir, "apt-get", "#!/bin/sh\necho called with: $@\nexit 0\n")
    with_fake_path(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    out = pepe(["browser", "install"])

    assert out =~ "apt-get"
    assert out =~ "install -y chromium"
    assert out =~ "called with: install -y chromium"
    assert out =~ "Done"
  end

  test "an install failure is reported, not swallowed" do
    dir = Path.join(System.tmp_dir!(), "pepe_browser_cli_fail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")
    fake_executable!(dir, "apt-get", "#!/bin/sh\necho simulated failure\nexit 3\n")
    with_fake_path(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    out = pepe(["browser", "install"])
    err = pepe_err(["browser", "install"])
    assert out =~ "simulated failure"
    assert err =~ "status 3"
  end

  test "with no known package manager, explains the fallback instead of hanging or crashing" do
    empty_path_dir = Path.join(System.tmp_dir!(), "pepe_browser_cli_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_path_dir)
    with_fake_path(empty_path_dir)
    on_exit(fn -> File.rm_rf(empty_path_dir) end)

    out = pepe(["browser", "install"])

    # macOS/Windows genuinely have nothing to install (a downloaded browser links
    # against what the OS always provides there, never a package manager) - this
    # message is reassuring, not an error, and differs from the real "I don't
    # recognize this Linux distro's package manager" case on purpose.
    case :os.type() do
      {:unix, :darwin} ->
        assert out =~ "Nothing to install"
        assert out =~ "macOS"
        assert out =~ "PEPE_CHROME_BINARY"

      {:win32, _} ->
        assert out =~ "Nothing to install"
        assert out =~ "Windows"
        assert out =~ "PEPE_CHROME_BINARY"

      _linux_or_other ->
        assert out =~ "Couldn't detect"
        assert out =~ "PEPE_CHROME_BINARY"
    end
  end

  test "mix pepe help browser explains what the command is for" do
    out = pepe(["help", "browser"])
    assert out =~ "mix pepe browser install"
    assert out =~ "Docker"
  end

  test "mix pepe browser (no subcommand) shows the same help" do
    out = pepe(["browser"])
    assert out =~ "mix pepe browser install"
  end
end
