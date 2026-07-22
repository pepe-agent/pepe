defmodule Pepe.BrowserTest do
  use ExUnit.Case, async: false

  # These drive a real Chromium/Chrome process over CDP - skipped wherever none is
  # installed (a CI runner with no browser package, or a machine that hasn't opted
  # into PEPE_IMAGE_APT_PACKAGES=chromium). The tool's own dispatch logic is covered
  # separately (and always) in Pepe.Tools.BrowserTest via a mocked Pepe.Browser.
  setup_all do
    if Pepe.Browser.Session.chrome_available?() do
      :ok
    else
      {:skip, "no Chromium/Chrome installed on this machine"}
    end
  end

  setup do
    key = "browser-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Pepe.Browser.close(key) end)
    %{key: key}
  end

  test "open navigates and returns a text snapshot with interactive elements", %{key: key} do
    assert {:ok, text} = Pepe.Browser.open(key, "https://example.com")
    assert text =~ "title: Example Domain"
    assert text =~ "interactive elements:"
    assert text =~ "[0] <a>"
  end

  test "snapshot re-describes the current page without navigating", %{key: key} do
    {:ok, _} = Pepe.Browser.open(key, "https://example.com")
    assert {:ok, text} = Pepe.Browser.snapshot(key)
    assert text =~ "Example Domain"
  end

  test "snapshot before open reports there's no session yet", %{key: key} do
    assert {:error, msg} = Pepe.Browser.snapshot(key)
    assert msg =~ "no browser session open"
  end

  test "click on a ref that no longer exists fails cleanly instead of hanging", %{key: key} do
    {:ok, _} = Pepe.Browser.open(key, "https://example.com")
    assert {:error, msg} = Pepe.Browser.click(key, 999)
    assert msg =~ "click failed"
  end

  test "close ends the session and a later action reports no session open", %{key: key} do
    {:ok, _} = Pepe.Browser.open(key, "https://example.com")
    assert {:ok, _} = Pepe.Browser.close(key)
    assert {:error, msg} = Pepe.Browser.snapshot(key)
    assert msg =~ "no browser session open"
  end

  test "close is a no-op when no session is open", %{key: key} do
    assert {:ok, msg} = Pepe.Browser.close(key)
    assert msg =~ "no browser session open"
  end

  test "refuses to navigate to a loopback address", %{key: key} do
    assert {:error, msg} = Pepe.Browser.open(key, "http://127.0.0.1:9/")
    assert msg =~ "internal/private"
  end

  test "refuses to navigate to a private RFC1918 address", %{key: key} do
    assert {:error, msg} = Pepe.Browser.open(key, "http://10.0.0.1/")
    assert msg =~ "internal/private"
  end

  test "refuses a non-http(s) scheme", %{key: key} do
    assert {:error, msg} = Pepe.Browser.open(key, "file:///etc/passwd")
    assert msg =~ "http/https"
  end

  test "refuses a URL with no host", %{key: key} do
    assert {:error, msg} = Pepe.Browser.open(key, "https:///no-host")
    assert msg =~ "http/https"
  end

  test "clicking a real link navigates normally, without deadlocking on the request guard", %{key: key} do
    # A real regression test for the request-guard deadlock this session fixed: arming CDP
    # Fetch-domain interception and resolving it from a separate linked process (rather than
    # this same GenServer, which blocks itself inside navigate/click's own `receive`) is what
    # keeps ordinary navigation working at all once every request has to be resolved.
    {:ok, _} = Pepe.Browser.open(key, "https://example.com")
    assert {:ok, text} = Pepe.Browser.click(key, 0)
    assert text =~ "iana.org"
  end
end
