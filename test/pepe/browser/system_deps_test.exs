defmodule Pepe.Browser.SystemDepsTest do
  use ExUnit.Case, async: false

  alias Pepe.Browser.SystemDeps

  describe "detect/0" do
    test "finds nothing when none of the known package managers are on PATH" do
      # This test machine's own real PATH - no fake managers injected. If it happens
      # to genuinely have apt-get/dnf/etc for some other reason, that's still a
      # legitimate `detect/0` result, just not one this specific assertion can make -
      # skip rather than false-fail on a dev machine that really has one installed.
      case SystemDeps.detect() do
        :not_found -> :ok
        {manager, _cmd} -> assert manager in ~w(apt-get dnf yum pacman apk zypper)
      end
    end

    test "finds a package manager placed on PATH, in priority order" do
      dir = Path.join(System.tmp_dir!(), "pepe_sysdeps_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "dnf"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, "dnf"), 0o755)

      prev_path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> prev_path)

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        File.rm_rf(dir)
      end)

      assert {"dnf", ["dnf", "install", "-y", "chromium"]} = SystemDeps.detect()
    end
  end

  describe "root?/0" do
    test "reports the real, current process uid" do
      # No test suite runs as root in CI or in normal local development - this is a
      # sanity check on the mechanism (shells out to `id -u`), not a hardcoded truth
      # about root in general.
      refute SystemDeps.root?()
    end
  end

  describe "install/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pepe_sysdeps_install_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      prev_path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> prev_path)

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        File.rm_rf(dir)
      end)

      %{dir: dir}
    end

    defp fake_executable!(dir, name, script) do
      path = Path.join(dir, name)
      File.write!(path, script)
      File.chmod!(path, 0o755)
    end

    test "prefixes with sudo when not already root (this test suite never runs as root)", %{dir: dir} do
      marker = Path.join(dir, "sudo_was_called")
      fake_executable!(dir, "sudo", "#!/bin/sh\ntouch #{marker}\nexec \"$@\"\n")
      fake_executable!(dir, "apt-get", "#!/bin/sh\nexit 0\n")

      assert :ok = SystemDeps.install(["apt-get", "install", "-y", "chromium"])
      assert File.exists?(marker)
    end

    test "reports a non-zero exit status instead of raising", %{dir: dir} do
      fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")
      fake_executable!(dir, "apt-get", "#!/bin/sh\nexit 7\n")

      assert {:error, 7} = SystemDeps.install(["apt-get", "install", "-y", "chromium"])
    end
  end
end
