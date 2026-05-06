defmodule Pepe.TUI do
  @moduledoc """
  Interactive terminal menus: a paginated, numbered `select` (one choice) and
  `multiselect` (several). You type the number(s) and press Enter; long lists
  (e.g. OpenRouter's 300+ models) page with `n`/`p` instead of scrolling off
  the top.

  Plain line-based input (via `Owl.IO.input`), so it works identically over a
  real terminal, an SSH session, a pipe, or CI - no raw-terminal mode, nothing
  to detect or fall back from. Localized via `Pepe.Gettext`, following the
  language chosen at setup.

  Options mirror `Owl.IO`: `:label` and `:render_as` (a 1-arity function turning
  an item into the text/iodata to show).
  """

  use Gettext, backend: Pepe.Gettext

  @page_size 20

  @doc "Pick one item by number. Returns the chosen item."
  def select(items, opts \\ [])
  def select([single], _opts), do: single
  def select([_ | _] = items, opts), do: paginated_select(items, render(opts), label(opts))

  @doc "Toggle items by number, Enter to finish. Returns the chosen list."
  def multiselect(items, opts \\ [])
  def multiselect([], _opts), do: []
  def multiselect([_ | _] = items, opts), do: paginated_multiselect(items, render(opts), label(opts))

  defp render(opts), do: Keyword.get(opts, :render_as, &to_string/1)
  defp label(opts), do: opts[:label] && to_string(opts[:label])

  ###
  ### paginated numbered list
  ###
  ###   Deliberately NOT overloading Enter for pagination: Enter is the universal
  ###   "submit what I typed", so `select` uses explicit `n`/`p` to page and a bare
  ###   Enter is a harmless no-op (never a hidden "next page"). `multiselect` keeps
  ###   the conventional bare-Enter = finish, since there numbers *toggle* rather
  ###   than pick, so "empty line = done" reads naturally and doesn't clash.
  ###

  defp paginated_select(items, render, label) do
    total = length(items)
    select_page(items, render, label, total, 0)
  end

  defp select_page(items, render, label, total, page) do
    print_page(items, render, label, page, page_count(total))
    ask_select(items, render, label, total, page)
  end

  # Re-ask on the same page without reprinting the list (so a stray Enter or an
  # invalid entry doesn't spam the whole page again).
  defp ask_select(items, render, label, total, page) do
    pages = page_count(total)

    case Owl.IO.input(label: select_hint(page, pages, total), cast: &parse_nav(&1, total), optional: true) do
      :same -> ask_select(items, render, label, total, page)
      :next -> select_page(items, render, label, total, next_page(page, pages))
      :prev -> select_page(items, render, label, total, prev_page(page, pages))
      {:pick, n} -> Enum.at(items, n - 1)
    end
  end

  defp paginated_multiselect(items, render, label) do
    total = length(items)
    multiselect_page(items, render, label, total, 0, MapSet.new())
  end

  defp multiselect_page(items, render, label, total, page, chosen) do
    print_page(items, render, label, page, page_count(total), chosen)
    ask_multi(items, render, label, total, page, chosen)
  end

  defp ask_multi(items, render, label, total, page, chosen) do
    pages = page_count(total)

    case Owl.IO.input(label: multi_hint(page, pages, total, chosen), cast: &parse_multi(&1, total), optional: true) do
      :done ->
        finish_multi(items, chosen)

      :next ->
        select_page_or(items, render, label, total, page < pages - 1, next_page(page, pages), chosen)

      :prev ->
        multiselect_page(items, render, label, total, prev_page(page, pages), chosen)

      {:toggle, numbers} ->
        chosen = Enum.reduce(numbers, chosen, &toggle_index/2)
        # re-render the same page so the [x] marks update
        multiselect_page(items, render, label, total, page, chosen)
    end
  end

  defp select_page_or(items, render, label, total, true, next, chosen),
    do: multiselect_page(items, render, label, total, next, chosen)

  defp select_page_or(items, _render, _label, _total, false, _next, chosen),
    do: finish_multi(items, chosen)

  defp finish_multi(items, chosen) do
    items
    |> Enum.with_index(1)
    |> Enum.filter(fn {_item, i} -> MapSet.member?(chosen, i) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp toggle_index(i, set), do: if(MapSet.member?(set, i), do: MapSet.delete(set, i), else: MapSet.put(set, i))

  defp page_count(total), do: div(total + @page_size - 1, @page_size)
  defp next_page(page, pages), do: rem(page + 1, pages)
  defp prev_page(page, pages), do: rem(page - 1 + pages, pages)

  defp print_page(items, render, label, page, pages, chosen \\ nil) do
    # A blank line first, so the menu is visually separated from whatever prompt
    # came before it (a preceding question, a confirm, the previous page).
    Owl.IO.puts([])
    if label, do: Owl.IO.puts(label)

    items
    |> Enum.slice(page * @page_size, @page_size)
    |> Enum.with_index(page * @page_size + 1)
    |> Enum.each(fn {item, i} ->
      Owl.IO.puts("#{checkbox(chosen, i)}#{i}. #{item |> render.() |> IO.iodata_to_binary()}")
    end)

    if pages > 1, do: Owl.IO.puts([dim(gettext("page %{page}/%{pages}", page: page + 1, pages: pages))])
    Owl.IO.puts([])
  end

  # Only multi-select passes a `chosen` set; single-select lines carry no checkbox.
  defp checkbox(nil, _i), do: ""
  defp checkbox(chosen, i), do: if(MapSet.member?(chosen, i), do: "[x] ", else: "[ ] ")

  # Single-select: number picks; n/p page. Enter is NOT a pagination command.
  # Spell out "type the number and press Enter" - a first-timer won't assume it.
  defp select_hint(page, pages, total) do
    if pages > 1 do
      gettext("Type the number of the option and press Enter.") <>
        "\n" <> dim("(#{range(page, total)}  ·  " <> gettext("n = next page  ·  p = previous page") <> ")")
    else
      gettext("Type the number of the option (1-%{total}) and press Enter.", total: total)
    end
  end

  # Multi-select: numbers toggle; n/p page; a blank line (just Enter) finishes.
  defp multi_hint(page, pages, total, chosen) do
    picked =
      case MapSet.size(chosen) do
        0 -> ""
        n -> "  ·  " <> gettext("%{count} marked", count: n)
      end

    nav = if pages > 1, do: "  ·  " <> gettext("n = next page  ·  p = previous"), else: ""

    gettext("Type the numbers you want to mark (e.g. 1 3) and press Enter.") <>
      "\n" <> dim("(#{range(page, total)}#{nav}  ·  " <> gettext("empty Enter to finish") <> ")#{picked}")
  end

  defp range(page, total) do
    first = page * @page_size + 1
    last = min(first + @page_size - 1, total)
    gettext("%{first}-%{last} of %{total}", first: first, last: last, total: total)
  end

  # Bare Enter is a no-op here (re-ask), never a hidden "next page".
  defp parse_nav(nil, _total), do: {:ok, :same}

  defp parse_nav(input, total) do
    case input |> String.trim() |> String.downcase() do
      "" -> {:ok, :same}
      c when c in ["n", "next", "próxima", "proxima"] -> {:ok, :next}
      c when c in ["p", "b", "prev", "back", "anterior"] -> {:ok, :prev}
      other -> parse_pick(other, total)
    end
  end

  defp parse_pick(other, total) do
    case Integer.parse(other) do
      {n, ""} when n >= 1 and n <= total ->
        {:ok, {:pick, n}}

      _ ->
        {:error, gettext("I didn't get that. Type a number from 1 to %{total} and press Enter (or n/p to change page).", total: total)}
    end
  end

  # Bare Enter finishes a multiselect (numbers toggle, so an empty line = done).
  defp parse_multi(nil, _total), do: {:ok, :done}

  defp parse_multi(input, total) do
    case input |> String.trim() |> String.downcase() do
      "" -> {:ok, :done}
      c when c in ["d", "done", "ok", "fim"] -> {:ok, :done}
      c when c in ["n", "next", "próxima", "proxima"] -> {:ok, :next}
      c when c in ["p", "b", "prev", "back", "anterior"] -> {:ok, :prev}
      other -> parse_toggle_numbers(other, total)
    end
  end

  defp parse_toggle_numbers(input, total) do
    parts = String.split(input, ~r/[,\s]+/, trim: true)

    numbers =
      Enum.reduce_while(parts, [], fn part, acc ->
        case Integer.parse(part) do
          {n, ""} when n >= 1 and n <= total -> {:cont, [n | acc]}
          _ -> {:halt, :error}
        end
      end)

    case numbers do
      :error ->
        {:error,
         gettext(
           "I didn't get that. Type numbers from 1 to %{total} separated by spaces and press Enter (n/p changes page · empty Enter finishes).",
           total: total
         )}

      nums ->
        {:ok, {:toggle, Enum.reverse(nums)}}
    end
  end

  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
