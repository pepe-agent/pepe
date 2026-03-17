defmodule Pepe.Gateways.Telegram.MarkdownTest do
  use ExUnit.Case, async: true

  alias Pepe.Gateways.Telegram.Markdown

  test "bold **..** and __..__ become <b>" do
    assert Markdown.to_html("é **amanhã às 09:00** e pronto") ==
             "é <b>amanhã às 09:00</b> e pronto"

    assert Markdown.to_html("__forte__") == "<b>forte</b>"
  end

  test "inline and fenced code" do
    assert Markdown.to_html("run `mix test` now") == "run <code>mix test</code> now"
    assert Markdown.to_html("```elixir\nIO.puts 1\n```") == "<pre>IO.puts 1\n</pre>"
  end

  test "links become anchors" do
    assert Markdown.to_html("see [docs](https://example.com/x)") ==
             ~s(see <a href="https://example.com/x">docs</a>)
  end

  test "html-special characters are escaped (valid, safe HTML)" do
    assert Markdown.to_html("a < b && c > d") == "a &lt; b &amp;&amp; c &gt; d"
    # a real tag in the text is neutralized, not passed through
    assert Markdown.to_html("<script>") == "&lt;script&gt;"
  end

  test "headings and bullets" do
    assert Markdown.to_html("# Título") == "<b>Título</b>"
    assert Markdown.to_html("- um\n- dois") == "• um\n• dois"
    # a bold line starting with ** is not mistaken for a bullet
    assert Markdown.to_html("**negrito**") == "<b>negrito</b>"
  end

  test "an unmatched delimiter is left as escaped text (never invalid HTML)" do
    assert Markdown.to_html("preço ** promoção") == "preço ** promoção"
  end

  test "italic with single * or _" do
    assert Markdown.to_html("isso é *itálico* aqui") == "isso é <i>itálico</i> aqui"
  end
end
