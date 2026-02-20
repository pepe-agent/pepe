defmodule Pepe.TUI do
  @moduledoc """
  Interactive terminal menus — arrow-key `select` and space-toggle `multiselect`.

  Pure Elixir, no NIF. Uses OTP 28's native **raw terminal mode**
  (`:shell.start_interactive({:noshell, :raw})`) to read keystrokes without echo
  or waiting for Enter, then decodes the `↑`/`↓` escape sequences.

  When raw mode isn't available (older OTP, no TTY, an active shell that won't
  hand over the terminal, pipes/CI/tests) it transparently falls back to Owl's
  numbered prompts, so the same calls keep working everywhere.

  Options mirror `Owl.IO`: `:label` and `:render_as` (a 1-arity function turning an
  item into the text/iodata to show).
  """

  @esc "\e"

  @doc "Pick one item with `↑`/`↓` + Enter. Returns the chosen item."
  def select(items, opts \\ [])
  def select([single], _opts), do: single
  def select([_ | _] = items, opts), do: run(items, opts, :select)

  @doc "Toggle items with Space, confirm with Enter. Returns the chosen list."
  def multiselect(items, opts \\ [])
  def multiselect([], _opts), do: []
  def multiselect([_ | _] = items, opts), do: run(items, opts, :multi)

  ###
  ### entry: raw-mode interactive, or Owl fallback
  ###

  defp run(items, opts, mode) do
    if tty?() and start_raw() == :ok do
      IO.write("#{@esc}[?25l")

      try do
        draw(items, render(opts), label(opts), 0, mode, MapSet.new())
        loop(items, render(opts), label(opts), 0, mode, MapSet.new())
      after
        IO.write("#{@esc}[?25h")
        restore()
      end
    else
      fallback(items, opts, mode)
    end
  end

  defp fallback(items, opts, :select), do: Owl.IO.select(items, owl_opts(opts))
  defp fallback(items, opts, :multi), do: Owl.IO.multiselect(items, owl_opts(opts))

  defp owl_opts(opts), do: Keyword.take(opts, [:label, :render_as, :min, :max])
  defp render(opts), do: Keyword.get(opts, :render_as, &to_string/1)
  defp label(opts), do: opts[:label] && to_string(opts[:label])

  ###
  ### loop
  ###

  defp loop(items, render, label, cursor, mode, selected) do
    last = length(items) - 1

    case read_key() do
      :up ->
        cursor = dec(cursor, last)
        redraw(items, render, label, cursor, mode, selected)
        loop(items, render, label, cursor, mode, selected)

      :down ->
        cursor = inc(cursor, last)
        redraw(items, render, label, cursor, mode, selected)
        loop(items, render, label, cursor, mode, selected)

      :space when mode == :multi ->
        selected = toggle(selected, cursor)
        redraw(items, render, label, cursor, mode, selected)
        loop(items, render, label, cursor, mode, selected)

      key when key in [:enter, :cancel, :eof] ->
        clear_block(menu_height(items, label))
        finish(items, mode, cursor, selected)

      _ ->
        loop(items, render, label, cursor, mode, selected)
    end
  end

  defp finish(items, :select, cursor, _selected), do: Enum.at(items, cursor)

  defp finish(items, :multi, _cursor, selected) do
    items
    |> Enum.with_index()
    |> Enum.filter(fn {_item, i} -> MapSet.member?(selected, i) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp toggle(set, i),
    do: if(MapSet.member?(set, i), do: MapSet.delete(set, i), else: MapSet.put(set, i))

  defp dec(0, last), do: last
  defp dec(c, _last), do: c - 1
  defp inc(c, last) when c >= last, do: 0
  defp inc(c, _last), do: c + 1

  ###
  ### rendering
  ###

  defp redraw(items, render, label, cursor, mode, selected) do
    IO.write("#{@esc}[#{menu_height(items, label)}A")
    draw(items, render, label, cursor, mode, selected)
  end

  defp draw(items, render, label, cursor, mode, selected) do
    for line <- lines(items, render, label, cursor, mode, selected) do
      IO.write("#{@esc}[2K" <> line <> "\r\n")
    end
  end

  defp lines(items, render, label, cursor, mode, selected) do
    header = if label, do: String.split(label, "\n"), else: []
    header ++ [hint(mode)] ++ rows(items, render, cursor, mode, selected)
  end

  defp rows(items, render, cursor, mode, selected) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} ->
      pointer = if i == cursor, do: cyan("›"), else: " "
      box = mark(mode, i, cursor, selected)
      text = item |> render.() |> IO.iodata_to_binary()
      "#{pointer} #{box} #{text}"
    end)
  end

  defp mark(:select, i, cursor, _selected), do: if(i == cursor, do: "(#{cyan("•")})", else: "( )")

  defp mark(:multi, i, _cursor, selected),
    do: if(MapSet.member?(selected, i), do: "[#{green("x")}]", else: "[ ]")

  defp hint(:select), do: dim("  ↑/↓ mover · enter selecionar")
  defp hint(:multi), do: dim("  ↑/↓ mover · espaço marcar · enter confirmar")

  defp menu_height(items, label) do
    header = if label, do: length(String.split(label, "\n")), else: 0
    header + 1 + length(items)
  end

  defp clear_block(height) do
    IO.write("#{@esc}[#{height}A")
    for _ <- 1..height, do: IO.write("#{@esc}[2K\r\n")
    IO.write("#{@esc}[#{height}A")
  end

  ###
  ### terminal / input (OTP 28 raw mode)
  ###

  # A TTY reports its width; pipes/files return an error.
  defp tty?, do: match?({:ok, _}, :io.columns())

  defp start_raw do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp restore do
    _ = :shell.start_interactive({:noshell, :cooked})
    :ok
  catch
    _, _ -> :ok
  end

  defp read_key do
    case getc() do
      @esc -> read_escape()
      "\r" -> :enter
      "\n" -> :enter
      " " -> :space
      "k" -> :up
      "j" -> :down
      "q" -> :cancel
      <<3>> -> :cancel
      :eof -> :eof
      _ -> :other
    end
  end

  defp read_escape do
    case getc() do
      "[" -> read_arrow()
      "O" -> read_arrow()
      _ -> :other
    end
  end

  defp read_arrow do
    case getc() do
      "A" -> :up
      "B" -> :down
      _ -> :other
    end
  end

  # Read a single character (raw mode → returns immediately, no echo).
  defp getc do
    case IO.getn(:stdio, "", 1) do
      :eof -> :eof
      {:error, _} -> :eof
      data -> to_string(data)
    end
  end

  ###
  ### colors
  ###

  defp cyan(s), do: IO.ANSI.cyan() <> s <> IO.ANSI.reset()
  defp green(s), do: IO.ANSI.green() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
