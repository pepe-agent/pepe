defmodule Pepe.Readable do
  @moduledoc """
  Strip an HTML page down to its actual readable content - the boilerplate
  (nav, ads, cookie banners, footers) `fetch_url` used to hand the model
  verbatim alongside the real text, burning context on none of it being the
  answer.

  A simplified version of the same idea Mozilla's Readability (and every port
  of it) implements: drop known-noise elements outright, then prefer a
  semantic content container (`article`/`main`/`[role=main]`) if the page
  bothered to mark one, and fall back to scoring the remaining block elements
  by how much of their text *isn't* inside a link (a paragraph that's mostly
  links is a nav/related-list, not prose). Not a port of the real algorithm -
  Mozilla's does far more (multi-page stitching, embed handling, readability
  scoring tuned on years of real sites) - just enough to turn "here's the
  whole page" into "here's what the page is actually about" for the common
  case (an article, a blog post, a docs page).

  Built on `Floki` directly, not the `readability` hex package: that package
  is Floki-based internally too, but unconditionally depends on
  httpoison/hackney for a URL-fetching convenience function this never needed,
  and that pulls an `idna` version this project's own lock file conflicts
  with.
  """

  @noise_selectors ~w(
    script style noscript template link meta
    nav header footer aside form iframe svg button
  )

  @content_selectors ~w(article main [role=main])

  # Below this many characters, extraction is considered to have found nothing
  # real (a JS-rendered SPA with no server-side content, a non-article page) -
  # the caller should fall back to the raw body rather than hand back a
  # near-empty "readable" result that looks successful but says nothing.
  @min_text_length 200

  @doc """
  `{:ok, %{title: title, text: text}}` for a page with real extractable
  content, `:error` otherwise (too little text found, or the HTML didn't
  parse at all).
  """
  @spec extract(String.t()) :: {:ok, %{title: String.t(), text: String.t()}} | :error
  def extract(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> extract_from_document(doc)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def extract(_), do: :error

  defp extract_from_document(doc) do
    title = extract_title(doc)
    clean = Floki.filter_out(doc, Enum.join(@noise_selectors, ", "))
    text = clean |> best_candidate() |> extract_text()

    if byte_size(text) >= @min_text_length, do: {:ok, %{title: title, text: text}}, else: :error
  end

  defp extract_title(doc) do
    case Floki.find(doc, "title") do
      [node | _] -> node |> Floki.text() |> String.trim()
      [] -> ""
    end
  end

  # A page's own semantic container wins outright if it has real content -
  # no need to score alternatives once the page has already told us where the
  # article is. Only falls through to scoring when none is present/substantial.
  defp best_candidate(clean) do
    Enum.find_value(@content_selectors, fn selector -> substantial_match(clean, selector) end) || best_scored_block(clean)
  end

  defp substantial_match(clean, selector) do
    case Floki.find(clean, selector) do
      [node | _] -> if text_length(node) >= @min_text_length, do: node
      [] -> nil
    end
  end

  defp best_scored_block(clean) do
    clean |> Floki.find("div, section, td") |> Enum.max_by(&block_score/1, fn -> clean end)
  end

  # Text outside any link, minus a per-link-count penalty (a block with many
  # short links - a nav list, a tag cloud - scores low even if its total text
  # happens to be long).
  defp block_score(node) do
    link_count = node |> Floki.find("a") |> length()
    own_text = node |> Floki.filter_out("a") |> Floki.text() |> String.length()
    own_text - link_count * 10
  end

  defp text_length(node), do: node |> Floki.text() |> String.length()

  # `table`/`td` deliberately excluded here: an infobox or data table (a Wikipedia
  # article's sidebar of short, dense facts, a spec sheet, ...) is real content but
  # not prose, and its cells sort earlier in document order than the article text
  # itself on the pages that have them most - counted in `best_scored_block/1`'s
  # candidate scoring, since a page that's *genuinely* a table (docs, a comparison
  # page) still needs to be found, just not blended into a prose extraction ahead of
  # the paragraphs a reader actually came for.
  defp extract_text(node) do
    node
    |> Floki.find("p, h1, h2, h3, h4, h5, h6, li, blockquote, pre")
    |> top_level_only()
    |> case do
      [] -> node |> Floki.text(sep: "\n\n") |> normalize_whitespace()
      blocks -> blocks |> Enum.map_join("\n\n", &(&1 |> Floki.text() |> String.trim())) |> normalize_whitespace()
    end
  end

  # Floki.find/2 returns nested matches too - a "loose list" (`<li><p>text</p></li>`,
  # common in rendered Markdown/READMEs) or a `<blockquote><p>text</p></blockquote>`
  # matches both the outer and the inner element, so naively joining every match's own
  # `Floki.text()` would put that same text in the output twice. Keep only the outermost
  # match in each nested group - its own `Floki.text()` already carries whatever text its
  # matched descendants have.
  defp top_level_only(blocks) do
    Enum.reject(blocks, fn block -> Enum.any?(blocks, &(&1 != block and contains?(&1, block))) end)
  end

  defp contains?({_tag, _attrs, children}, target) when is_list(children),
    do: Enum.any?(children, &(&1 == target or contains?(&1, target)))

  defp contains?(_node, _target), do: false

  defp normalize_whitespace(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end
end
