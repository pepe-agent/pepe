defmodule Pepe.Tools.FetchUrlTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Tools.FetchUrl

  @html_article """
  <html><head><title>A Real Article</title></head><body>
    <nav><a href="/">Home</a></nav>
    <article><p>#{String.duplicate("This is the actual article content a reader wants. ", 6)}</p></article>
    <footer>Copyright 2026. Privacy policy.</footer>
  </body></html>
  """

  defp stub_response(status, headers, body) do
    Mimic.stub(Req, :get, fn _url, _opts -> {:ok, %{status: status, headers: headers, body: body}} end)
  end

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

  test "the actual request is pinned to the resolved address, not re-resolved at connect time" do
    # Regression test for the DNS-rebinding gap: resolving and validating a host, then handing
    # Req the bare hostname to resolve again on its own, means an attacker who controls DNS for
    # that host can answer differently the second time (a public IP for this check, an internal
    # one for the real connection) and slip straight past the guard above. Asserting on what
    # actually reaches Req.get is what makes this a regression test rather than a hope - the URL
    # host must already be a numeric IP address by the time it gets there, with the real
    # hostname preserved only in connect_options (for the Host header, SNI, and certificate
    # verification - see Mint.HTTP.connect/4).
    Mimic.expect(Req, :get, fn url, opts ->
      uri = URI.parse(url)
      assert {:ok, _} = Pepe.Net.parse_address(uri.host)
      assert opts[:connect_options][:hostname] == "example.com"
      {:ok, %{status: 200, headers: %{}, body: "ok"}}
    end)

    assert {:ok, _} = FetchUrl.run(%{"url" => "https://example.com/"}, %{})
  end

  test "an IPv6 target is pinned with a single, valid bracket pair" do
    # Regression test: the pinned host was wrapped in brackets by hand and then wrapped again by
    # URI.to_string/1 (which already brackets any host containing `:`), producing the doubled,
    # unparseable authority `[[::1]]`. A real public IPv6 literal (Google's public DNS) as the
    # URL's own host skips DNS entirely (Pepe.Net.parse_address/1 recognizes it directly), so
    # this exercises pin_host/2 without depending on IPv6 connectivity in CI.
    Mimic.expect(Req, :get, fn url, _opts ->
      assert url == "https://[2001:4860:4860::8888]/"
      assert {:ok, _} = URI.new(url)
      {:ok, %{status: 200, headers: %{}, body: "ok"}}
    end)

    assert {:ok, _} = FetchUrl.run(%{"url" => "https://[2001:4860:4860::8888]/"}, %{})
  end

  describe "readable-text extraction" do
    test "an HTML response is reduced to its readable text by default" do
      stub_response(200, %{"content-type" => ["text/html; charset=utf-8"]}, @html_article)

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/article"}, %{})

      assert out =~ "status=200"
      assert out =~ "A Real Article"
      assert out =~ "actual article content"
      refute out =~ "Copyright"
      refute out =~ "Home"
    end

    test "raw: true skips extraction and returns the body untouched" do
      stub_response(200, %{"content-type" => ["text/html; charset=utf-8"]}, @html_article)

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/article", "raw" => true}, %{})

      assert out =~ "<article>"
      assert out =~ "<nav>"
      assert out =~ "Copyright"
    end

    test "a non-HTML content type is never run through extraction" do
      stub_response(200, %{"content-type" => ["application/json"]}, ~s({"hello":"world"}))

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/api"}, %{})

      assert out =~ "status=200"
      assert out =~ ~s({"hello":"world"})
    end

    test "a response with no content-type header falls back to the raw body" do
      stub_response(200, %{}, "plain text, no headers at all")

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/x"}, %{})

      assert out =~ "status=200"
      assert out =~ "plain text, no headers at all"
    end

    test "HTML with nothing extractable (a link list, no real prose) falls back to the raw body" do
      thin_html = ~s(<html><head><title>t</title></head><body><a href="/1">One</a> <a href="/2">Two</a></body></html>)
      stub_response(200, %{"content-type" => ["text/html"]}, thin_html)

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/links"}, %{})

      assert out =~ "<html>"
      assert out =~ "<a href="
    end

    test "a page over the size cap skips extraction entirely rather than parsing something huge" do
      huge = "<html><head><title>t</title></head><body><article>" <> String.duplicate("x", 3_000_001) <> "</article></body></html>"
      stub_response(200, %{"content-type" => ["text/html"]}, huge)

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/huge"}, %{})

      # Never reaches Pepe.Readable at all - just the existing raw+truncate path.
      assert out =~ "...(truncated)"
    end
  end

  describe "untrusted content marker" do
    test "the fetched content is wrapped in an explicit untrusted-content marker" do
      stub_response(200, %{"content-type" => ["application/json"]}, ~s({"hello":"world"}))

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/api"}, %{})

      assert out =~ "BEGIN UNTRUSTED EXTERNAL CONTENT"
      assert out =~ "source: fetch_url"
      assert out =~ "END UNTRUSTED EXTERNAL CONTENT"
      # The status= line is Pepe's own bookkeeping, not part of what the page said - it
      # stays outside the marker rather than being framed as untrusted itself.
      assert out =~ ~r/\Astatus=200\n=== BEGIN UNTRUSTED/
    end
  end
end
