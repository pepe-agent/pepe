defmodule Pepe.Gateways.Telegram.Markdown do
  @moduledoc """
  Convert the CommonMark-ish markdown models emit into the small subset of HTML that
  Telegram's `parse_mode: "HTML"` accepts - so `**bold**`, `` `code` ``, fenced blocks
  and links render instead of arriving as literal asterisks.

  HTML is used over MarkdownV2 because it needs far less escaping to stay valid. The
  text is HTML-escaped first, then markdown tokens are turned into tags; anything
  unmatched (a stray `**`) is left as escaped text, so the output is always valid HTML
  (Telegram rejects malformed entities). Only tags Telegram allows are emitted
  (`b`, `i`, `code`, `pre`, `a`).
  """

  @doc "Markdown -> Telegram-safe HTML."
  def to_html(text) when is_binary(text) do
    text
    |> escape()
    |> fenced_code()
    |> inline_code()
    |> bold()
    |> italic()
    |> links()
    |> headings()
    |> bullets()
  end

  def to_html(text), do: text |> to_string() |> to_html()

  defp escape(t) do
    t
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ```lang\n...\n``` -> <pre>...</pre>
  defp fenced_code(t) do
    Regex.replace(~r/```[^\n]*\n(.*?)```/s, t, fn _, code -> "<pre>#{code}</pre>" end)
  end

  defp inline_code(t), do: Regex.replace(~r/`([^`\n]+)`/, t, "<code>\\1</code>")

  defp bold(t) do
    t
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/s, &1, "<b>\\1</b>"))
    |> then(&Regex.replace(~r/__(.+?)__/s, &1, "<b>\\1</b>"))
  end

  # single *italic* / _italic_ - only when not part of ** (handled above) and not a
  # bullet ("* item", caught by the trailing-space exclusion).
  defp italic(t) do
    t
    |> then(&Regex.replace(~r/(?<![\*\w])\*(?![\s\*])([^*\n]+?)\*(?![\*\w])/, &1, "<i>\\1</i>"))
    |> then(&Regex.replace(~r/(?<![_\w])_(?![\s_])([^_\n]+?)_(?![_\w])/, &1, "<i>\\1</i>"))
  end

  defp links(t) do
    Regex.replace(~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/, t, "<a href=\"\\2\">\\1</a>")
  end

  # markdown headings -> a bold line
  defp headings(t), do: Regex.replace(~r/^\s*\#{1,6}\s+(.+)$/m, t, "<b>\\1</b>")

  # "- item" / "* item" -> "• item"
  defp bullets(t), do: Regex.replace(~r/^(\s*)[-*]\s+/m, t, "\\1• ")
end
