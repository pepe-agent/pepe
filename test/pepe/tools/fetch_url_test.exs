defmodule Pepe.Tools.FetchUrlTest do
  use ExUnit.Case, async: true

  alias Pepe.Tools.FetchUrl

  test "rejects non-http(s) schemes" do
    assert {:error, msg} = FetchUrl.run(%{"url" => "file:///etc/passwd"}, %{})
    assert msg =~ "only http/https"
  end

  test "rejects a URL with no host" do
    assert {:error, msg} = FetchUrl.run(%{"url" => "http:///no-host"}, %{})
    assert msg =~ "only http/https"
  end

  test "rejects an unparseable URL" do
    assert {:error, msg} = FetchUrl.run(%{"url" => "://not a url"}, %{})
    assert msg =~ "invalid URL"
  end

  test "rejects loopback IPv4 and IPv6 literals" do
    assert {:error, msg} = FetchUrl.run(%{"url" => "http://127.0.0.1/"}, %{})
    assert msg =~ "internal/private"

    assert {:error, msg} = FetchUrl.run(%{"url" => "http://[::1]/"}, %{})
    assert msg =~ "internal/private"
  end

  test "rejects RFC1918 private ranges" do
    for host <- ["10.0.0.5", "172.16.4.4", "192.168.1.1"] do
      assert {:error, msg} = FetchUrl.run(%{"url" => "http://#{host}/"}, %{})
      assert msg =~ "internal/private"
    end
  end

  test "rejects the cloud-metadata link-local address" do
    assert {:error, msg} = FetchUrl.run(%{"url" => "http://169.254.169.254/latest/meta-data/"}, %{})
    assert msg =~ "internal/private"
  end

  test "missing url param still errors as before" do
    assert {:error, "missing 'url'"} = FetchUrl.run(%{}, %{})
  end

  test "a hostname (not a literal IP) actually resolves and is checked against the real address" do
    # Regression test: :inet.gethostbyname/2 returns its result as a plain
    # {:hostent, ...} tuple, not a %{h_addr_list: ...} map - matching the wrong
    # shape silently made every hostname resolve to zero addresses, which meant
    # every non-literal-IP fetch failed with "could not resolve host" instead of
    # actually being checked. "localhost" always resolves to 127.0.0.1, so this
    # must be rejected as internal, not as unresolvable.
    assert {:error, msg} = FetchUrl.run(%{"url" => "http://localhost/"}, %{})
    assert msg =~ "internal/private"
    refute msg =~ "could not resolve"
  end
end
