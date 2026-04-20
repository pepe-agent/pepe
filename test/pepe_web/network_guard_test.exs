defmodule PepeWeb.NetworkGuardTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias PepeWeb.NetworkGuard

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_netguard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp set_dashboard(map), do: Config.save(Map.put(Config.load(), "dashboard", map))

  describe "host_allowed?/1" do
    test "loopback names are always allowed, no password or allowlist needed" do
      for host <- ["localhost", "127.0.0.1", "127.5.5.5", "::1", "[::1]", "0.0.0.0"] do
        assert NetworkGuard.host_allowed?(host), "expected #{host} to be allowed"
      end
    end

    test "with no allowlist and no password, a remote host is rejected" do
      refute NetworkGuard.host_allowed?("evil.example.com")
    end

    test "with no allowlist but a password set, any host is allowed" do
      set_dashboard(%{"password" => "s3cret"})
      assert NetworkGuard.host_allowed?("random-subdomain.trycloudflare.com")
    end

    test "with an explicit allowlist, only listed hosts pass, case-insensitively" do
      set_dashboard(%{"allowed_hosts" => ["App.Example.com"]})
      assert NetworkGuard.host_allowed?("app.example.com")
      refute NetworkGuard.host_allowed?("other.example.com")
    end

    test "an allowlist takes precedence even when a password is also set" do
      set_dashboard(%{"password" => "s3cret", "allowed_hosts" => ["app.example.com"]})
      assert NetworkGuard.host_allowed?("app.example.com")
      refute NetworkGuard.host_allowed?("random.trycloudflare.com")
    end
  end

  describe "PepeWeb.Endpoint.check_live_origin?/1" do
    test "a nil host (malformed origin) is rejected" do
      refute PepeWeb.Endpoint.check_live_origin?(%URI{host: nil})
    end

    test "delegates to NetworkGuard.host_allowed?/1 for a real host" do
      assert PepeWeb.Endpoint.check_live_origin?(%URI{host: "localhost"})

      refute PepeWeb.Endpoint.check_live_origin?(%URI{host: "evil.example.com"})

      set_dashboard(%{"password" => "s3cret"})
      assert PepeWeb.Endpoint.check_live_origin?(%URI{host: "random.trycloudflare.com"})
    end
  end
end
