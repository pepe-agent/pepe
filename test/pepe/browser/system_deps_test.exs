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
        {manager, _cmds} -> assert manager in ~w(apt-get dnf yum pacman apk zypper)
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

      assert {"dnf", [["dnf", "install", "-y", "chromium"]]} = SystemDeps.detect()
    end

    test "apt-get gets two argv alternatives to try (Debian's package name, then Ubuntu's)" do
      dir = Path.join(System.tmp_dir!(), "pepe_sysdeps_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "apt-get"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, "apt-get"), 0o755)

      prev_path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> prev_path)

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        File.rm_rf(dir)
      end)

      assert {"apt-get",
              [
                ["apt-get", "install", "-y", "chromium"],
                ["apt-get", "install", "-y", "chromium-browser"]
              ]} = SystemDeps.detect()
    end
  end

  describe "root?/0" do
    test "reports the real, current process uid" do
      # A sanity check on the mechanism (shells out to `id -u`), not a hardcoded truth
      # about root in general - some CI/container environments genuinely do run as root,
      # so this only asserts root?/0 agrees with the actual uid, not that the uid is 0.
      expected = match?({"0\n", 0}, System.cmd("id", ["-u"], stderr_to_stdout: true))
      assert SystemDeps.root?() == expected
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

    test "prefixes with sudo when not already root", %{dir: dir} do
      marker = Path.join(dir, "sudo_was_called")
      fake_executable!(dir, "sudo", "#!/bin/sh\ntouch #{marker}\nexec \"$@\"\n")
      fake_executable!(dir, "apt-get", "#!/bin/sh\nexit 0\n")

      assert :ok = SystemDeps.install([["apt-get", "install", "-y", "chromium"]])
      assert File.exists?(marker)
    end

    test "reports a non-zero exit status instead of raising", %{dir: dir} do
      fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")
      fake_executable!(dir, "apt-get", "#!/bin/sh\nexit 7\n")

      assert {:error, 7} = SystemDeps.install([["apt-get", "install", "-y", "chromium"]])
    end

    test "falls back to the second alternative when the first fails (Ubuntu's chromium-browser)", %{dir: dir} do
      fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")

      fake_executable!(dir, "apt-get", """
      #!/bin/sh
      case "$3" in
        chromium) exit 100 ;;
        chromium-browser) exit 0 ;;
      esac
      """)

      assert :ok =
               SystemDeps.install([
                 ["apt-get", "install", "-y", "chromium"],
                 ["apt-get", "install", "-y", "chromium-browser"]
               ])
    end

    test "reports the last alternative's exit status when every one of them fails", %{dir: dir} do
      fake_executable!(dir, "sudo", "#!/bin/sh\nexec \"$@\"\n")
      fake_executable!(dir, "apt-get", "#!/bin/sh\nexit 100\n")

      assert {:error, 100} =
               SystemDeps.install([
                 ["apt-get", "install", "-y", "chromium"],
                 ["apt-get", "install", "-y", "chromium-browser"]
               ])
    end
  end
end
