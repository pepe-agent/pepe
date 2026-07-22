defmodule Pepe.Browser.SessionTest do
  @moduledoc """
  `Pepe.Browser.Session`'s SSRF guard, tested directly (no live Chrome/browser needed) -
  see `Pepe.Browser.SessionTest` vs. `Pepe.BrowserTest`'s own live, chrome-gated tests.
  """
  use ExUnit.Case, async: true

  alias Pepe.Browser.Session

  describe "validate_url/1 (the `open` entry point - requires http/https)" do
    test "allows an ordinary public http(s) URL" do
      assert Session.validate_url("https://example.com/path") == :ok
    end

    test "refuses a loopback address" do
      assert {:error, msg} = Session.validate_url("http://127.0.0.1:9/")
      assert msg =~ "internal/private"
    end

    test "refuses an RFC1918 private address" do
      assert {:error, msg} = Session.validate_url("http://10.0.0.1/")
      assert msg =~ "internal/private"
    end

    test "refuses a link-local (cloud metadata) address" do
      assert {:error, msg} = Session.validate_url("http://169.254.169.254/")
      assert msg =~ "internal/private"
    end

    test "refuses a non-http(s) scheme" do
      assert {:error, msg} = Session.validate_url("file:///etc/passwd")
      assert msg =~ "http/https"
    end

    test "refuses a URL with no host" do
      assert {:error, msg} = Session.validate_url("https:///no-host")
      assert msg =~ "http/https"
    end
  end

  describe "request_url_allowed?/1 (every request after that, via CDP Fetch interception)" do
    test "allows an ordinary public http(s) request" do
      assert Session.request_url_allowed?("https://example.com/style.css")
    end

    test "blocks a request to a loopback address" do
      refute Session.request_url_allowed?("http://127.0.0.1:9/")
    end

    test "blocks a request to an RFC1918 private address" do
      refute Session.request_url_allowed?("http://192.168.1.1/admin")
    end

    test "blocks a request to a link-local (cloud metadata) address" do
      refute Session.request_url_allowed?("http://169.254.169.254/latest/meta-data")
    end

    test "lets a non-http(s) request through unchecked (not a network fetch to a host)" do
      assert Session.request_url_allowed?("data:text/plain;base64,aGVsbG8=")
      assert Session.request_url_allowed?("blob:https://example.com/abc-123")
      assert Session.request_url_allowed?("about:blank")
    end
  end
end
