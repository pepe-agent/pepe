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

      assert out == "status=200\n{\"hello\":\"world\"}"
    end

    test "a response with no content-type header falls back to the raw body" do
      stub_response(200, %{}, "plain text, no headers at all")

      {:ok, out} = FetchUrl.run(%{"url" => "https://example.com/x"}, %{})

      assert out == "status=200\nplain text, no headers at all"
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
end
