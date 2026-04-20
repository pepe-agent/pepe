defmodule Pepe.ServiceInstallTest do
  use ExUnit.Case, async: false

  alias Pepe.ServiceInstall

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_svc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  # mix test never runs from the packaged Burrito binary, so install/1 always
  # hits this branch - real launchctl/systemctl invocations are exercised
  # manually against a real build, not here.
  test "install refuses outside the packaged binary" do
    assert {:error, msg} = ServiceInstall.install()
    assert msg =~ "mix pepe"
  end

  test "install refuses regardless of a --port option" do
    assert {:error, _} = ServiceInstall.install(port: 5000)
  end

  # status/uninstall don't need a stable bin path, so they run for real even
  # under mix test - against a service that (almost certainly) isn't
  # installed on the test machine, which both handle gracefully.
  test "status reports not installed when nothing is registered" do
    assert {:ok, msg} = ServiceInstall.status()
    assert is_binary(msg)
  end

  test "uninstall is a safe no-op when nothing is installed" do
    assert {:ok, _msg} = ServiceInstall.uninstall()
  end

  describe "macos_plist/2" do
    test "embeds the binary path, serve, and the label" do
      xml = ServiceInstall.macos_plist("/usr/local/bin/pepe", [])

      assert xml =~ "<string>/usr/local/bin/pepe</string>"
      assert xml =~ "<string>serve</string>"
      assert xml =~ "com.pepe-agent.serve"
      assert xml =~ "<key>RunAtLoad</key>"
      assert xml =~ "<key>KeepAlive</key>"
    end

    test "adds --port args when given" do
      xml = ServiceInstall.macos_plist("/usr/local/bin/pepe", port: 5050)
      assert xml =~ "<string>--port</string>"
      assert xml =~ "<string>5050</string>"
    end

    test "omits --port args when not given" do
      xml = ServiceInstall.macos_plist("/usr/local/bin/pepe", [])
      refute xml =~ "--port"
    end

    test "escapes XML special characters in the binary path" do
      xml = ServiceInstall.macos_plist("/opt/a&b/pepe", [])
      assert xml =~ "/opt/a&amp;b/pepe"
      refute xml =~ "/opt/a&b/pepe"
    end

    test "includes PEPE_HOME in EnvironmentVariables when set", %{home: home} do
      xml = ServiceInstall.macos_plist("/usr/local/bin/pepe", [])
      assert xml =~ "<key>EnvironmentVariables</key>"
      assert xml =~ "<key>PEPE_HOME</key>"
      assert xml =~ "<string>#{home}</string>"
    end
  end

  describe "linux_unit/2" do
    test "embeds the binary path and serve in ExecStart" do
      ini = ServiceInstall.linux_unit("/usr/local/bin/pepe", [])
      assert ini =~ "ExecStart=/usr/local/bin/pepe serve"
      assert ini =~ "Restart=always"
    end

    test "adds --port to ExecStart when given" do
      ini = ServiceInstall.linux_unit("/usr/local/bin/pepe", port: 5050)
      assert ini =~ "ExecStart=/usr/local/bin/pepe serve --port 5050"
    end

    test "includes PEPE_HOME as an Environment= line when set", %{home: home} do
      ini = ServiceInstall.linux_unit("/usr/local/bin/pepe", [])
      assert ini =~ "Environment=PEPE_HOME=#{home}"
    end
  end
end
