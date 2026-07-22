defmodule Pepe.ReadableTest do
  use ExUnit.Case, async: true

  alias Pepe.Readable

  test "extracts the article body, dropping nav/header/aside/footer/script noise" do
    html = """
    <html>
    <head><title>My Article Title</title></head>
    <body>
      <nav><a href="/">Home</a><a href="/about">About</a></nav>
      <header><h1>Site Header Junk</h1></header>
      <article>
        <h1>The Real Article Title</h1>
        <p>This is the first paragraph of real content that matters a lot to the reader here.</p>
        <p>This is a second paragraph with more substantive content about the actual topic at length.</p>
        <p>And a third paragraph to make sure there is enough text to pass the minimum length threshold.</p>
      </article>
      <aside><h3>Related</h3><ul><li><a href="/1">Link 1</a></li><li><a href="/2">Link 2</a></li></ul></aside>
      <footer>Copyright 2026. All rights reserved. Privacy policy. Terms of service.</footer>
      <script>console.log("tracking");</script>
    </body>
    </html>
    """

    assert {:ok, %{title: "My Article Title", text: text}} = Readable.extract(html)
    assert text =~ "The Real Article Title"
    assert text =~ "first paragraph of real content"
    refute text =~ "Site Header Junk"
    refute text =~ "Related"
    refute text =~ "Copyright"
    refute text =~ "tracking"
  end

  test "an infobox/data table doesn't crowd out the actual prose" do
    prose = String.duplicate("Real article prose that a reader actually came here for. ", 10)

    html = """
    <html><head><title>t</title></head><body>
      <table>
        <tr><td>Paradigm</td><td>functional</td></tr>
        <tr><td>Designer</td><td>Someone</td></tr>
        <tr><td>First appeared</td><td>2012</td></tr>
      </table>
      <article><p>#{prose}</p></article>
    </body></html>
    """

    assert {:ok, %{text: text}} = Readable.extract(html)
    assert text =~ "Real article prose"
    refute text =~ "Paradigm"
  end

  test "falls back to scoring blocks when the page has no semantic container" do
    prose = String.duplicate("This div is the real content of the page, not a navigation list. ", 5)

    html = """
    <html><head><title>t</title></head><body>
      <div class="nav"><a href="/1">One</a><a href="/2">Two</a><a href="/3">Three</a><a href="/4">Four</a></div>
      <div class="content">#{prose}</div>
    </body></html>
    """

    assert {:ok, %{text: text}} = Readable.extract(html)
    assert text =~ "real content of the page"
  end

  test "a page with too little real text fails extraction rather than returning noise" do
    html = """
    <html><head><title>Front page</title></head><body>
      <div><a href="/1">One</a> <a href="/2">Two</a> <a href="/3">Three</a></div>
    </body></html>
    """

    assert Readable.extract(html) == :error
  end

  test "malformed HTML doesn't crash extraction" do
    result = Readable.extract("<html><body><p>unclosed paragraph<div>broken nesting")
    assert match?(:error, result) or match?({:ok, %{}}, result)
  end

  test "empty or non-HTML input returns :error, not a crash" do
    assert Readable.extract("") == :error
    assert Readable.extract("not html at all, just plain text") == :error
    assert Readable.extract(nil) == :error
    assert Readable.extract(123) == :error
  end
end
