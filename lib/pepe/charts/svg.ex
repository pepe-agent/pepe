defmodule Pepe.Charts.Svg do
  @moduledoc """
  Draws a bar, line or pie chart as a self-contained SVG string, in the dashboard's own look:
  near-black card, hairline grid, closed low-contrast colors.

  Pure: data in, string out, no files and no external tool. Turning the SVG into a PNG (what a
  chat app can show) is `Pepe.Charts.Raster`'s job.

  A chart is a map:

      %{
        type: :bar | :line | :pie,
        title: "Weekly signups" | nil,
        labels: ["Mon", "Tue"],
        series: [%{name: "This week", values: [3, 5], tone: :gold | nil}],
        prefix: "$", suffix: "%"        # both optional, put around every number
      }

  A pie takes one series and reads it as the parts of a whole.
  """

  @width 1000
  @height 560
  @font "Helvetica, Arial, 'DejaVu Sans', sans-serif"

  @bg "#0f1921"
  @border "#ffffff1f"
  @ink "#e6edf3"
  @muted "#8a9aa7"
  @grid "#ffffff12"

  # Closed on purpose: they sit on a dark card and should belong to it. Red is for something that
  # went wrong and is only used when asked for.
  @tones %{gold: "#d6a93c", teal: "#2f9e91", slate: "#7890a3", red: "#c9645c", copper: "#b07a5a", moss: "#6f8f5f"}
  @cycle [:gold, :teal, :slate, :copper, :moss, :red]

  # `:math.pi/0` is not allowed in a guard, so the full turn is a constant.
  @full_turn 2 * :math.pi() - 1.0e-6

  @type chart :: map()

  @doc "The chart as an SVG document."
  @spec render(chart()) :: String.t()
  def render(chart) do
    chart = normalise(chart)

    body =
      case chart.type do
        :pie -> pie(chart)
        :line -> cartesian(chart, :line)
        :bar -> cartesian(chart, :bar)
      end

    IO.iodata_to_binary([
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}" font-family="#{@font}">),
      ~s(<rect x="0.5" y="0.5" width="#{@width - 1}" height="#{@height - 1}" rx="18" fill="#{@bg}" stroke="#{@border}"/>),
      title(chart),
      body,
      "</svg>"
    ])
  end

  ###
  ### input
  ###

  defp normalise(chart) do
    series =
      chart.series
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        tone = s[:tone] || Enum.at(@cycle, rem(i, length(@cycle)))
        %{name: to_string(s[:name] || ""), values: Enum.map(s.values, &num/1), color: Map.get(@tones, tone, @tones.gold)}
      end)

    %{
      type: chart.type,
      title: chart[:title],
      labels: Enum.map(chart.labels, &to_string/1),
      series: series,
      prefix: chart[:prefix] || "",
      suffix: chart[:suffix] || ""
    }
  end

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0

  ###
  ### title and legend
  ###

  defp title(%{title: nil}), do: ""
  defp title(%{title: ""}), do: ""

  defp title(%{title: text}),
    do: ~s(<text x="44" y="56" fill="#{@ink}" font-size="24" font-weight="600">#{esc(clip(text, 60))}</text>)

  defp legend(%{series: [_]}), do: ""

  defp legend(%{series: series}) do
    # Right-aligned, walking leftwards from the card's edge so a long name cannot run off it.
    {items, _x} =
      series
      |> Enum.reverse()
      |> Enum.map_reduce(@width - 44, fn s, x ->
        name = clip(s.name, 22)
        w = text_width(name, 15) + 26

        item =
          ~s(<rect x="#{f(x - w)}" y="42" width="12" height="5" rx="2.5" fill="#{s.color}"/><text x="#{f(x - w + 20)}" y="50" fill="#{@muted}" font-size="15">#{esc(name)}</text>)

        {item, x - w - 18}
      end)

    Enum.reverse(items)
  end

  ###
  ### bars and lines
  ###

  defp cartesian(chart, kind) do
    left = 84
    right = @width - 44
    top = 92
    bottom = @height - 64

    all = List.flatten(Enum.map(chart.series, & &1.values))
    {lo, hi} = {min(0.0, Enum.min(all, fn -> 0.0 end)), max(0.0, Enum.max(all, fn -> 0.0 end))}
    ticks = ticks(lo, hi)
    {y_min, y_max} = {List.first(ticks), List.last(ticks)}

    y = fn v -> bottom - (v - y_min) / max(y_max - y_min, 1.0e-9) * (bottom - top) end
    count = max(length(chart.labels), 1)
    slot = (right - left) / count
    x_mid = fn i -> left + slot * (i + 0.5) end

    [
      legend(chart),
      Enum.map(ticks, fn t ->
        ~s(<line x1="#{left}" x2="#{right}" y1="#{f(y.(t))}" y2="#{f(y.(t))}" stroke="#{@grid}"/>) <>
          ~s(<text x="#{left - 12}" y="#{f(y.(t) + 5)}" fill="#{@muted}" font-size="15" text-anchor="end">#{esc(tick_label(t, ticks, chart))}</text>)
      end),
      x_labels(chart.labels, x_mid, bottom + 30, slot),
      if(kind == :bar, do: bars(chart, left, slot, y), else: lines(chart, x_mid, y, bottom))
    ]
  end

  defp bars(chart, left, slot, y) do
    n = max(length(chart.series), 1)
    group = min(slot * 0.72, 120.0)
    bar = group / n
    zero = y.(0.0)

    chart.series
    |> Enum.with_index()
    |> Enum.flat_map(fn {s, si} ->
      s.values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        x = left + slot * (i + 0.5) - group / 2 + bar * si
        top = min(y.(v), zero)
        h = max(abs(zero - y.(v)), 1.0)
        ~s(<rect x="#{f(x + 1)}" y="#{f(top)}" width="#{f(max(bar - 2, 1.0))}" height="#{f(h)}" rx="3" fill="#{s.color}"/>)
      end)
    end)
  end

  defp lines(chart, x_mid, y, bottom) do
    many? = match?([_, _ | _], chart.series)

    chart.series
    |> Enum.with_index()
    |> Enum.map(fn {s, si} ->
      points = s.values |> Enum.with_index() |> Enum.map(fn {v, i} -> {x_mid.(i), y.(v)} end)
      path = Enum.map_join(points, " ", fn {px, py} -> "#{f(px)},#{f(py)}" end)

      [
        if(si == 0 and not many?, do: wash(points, path, bottom, s.color), else: ""),
        ~s(<polyline points="#{path}" fill="none" stroke="#{s.color}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>),
        dots(points, s.color)
      ]
    end)
  end

  # A wash under the lead series only; two of them on top of each other turn to mud.
  defp wash([_, _ | _] = points, path, bottom, color) do
    {fx, _} = List.first(points)
    {lx, _} = List.last(points)
    ~s(<polygon points="#{f(fx)},#{f(bottom)} #{path} #{f(lx)},#{f(bottom)}" fill="#{color}" opacity="0.09"/>)
  end

  defp wash(_points, _path, _bottom, _color), do: ""

  # A marker per point while they are few enough to tell apart.
  defp dots(points, color) do
    if Enum.count_until(points, 25) < 25 do
      Enum.map(points, fn {px, py} ->
        ~s(<circle cx="#{f(px)}" cy="#{f(py)}" r="4.5" fill="#{@bg}" stroke="#{color}" stroke-width="2.5"/>)
      end)
    else
      []
    end
  end

  # Every label when they fit, every nth when they would touch.
  defp x_labels(labels, x_mid, y, slot) do
    longest = labels |> Enum.map(&text_width(clip(&1, 14), 15)) |> Enum.max(fn -> 0 end)
    step = max(ceil((longest + 14) / max(slot, 1.0)), 1)

    labels
    |> Enum.with_index()
    |> Enum.filter(fn {_l, i} -> rem(i, step) == 0 end)
    |> Enum.map(fn {l, i} ->
      ~s(<text x="#{f(x_mid.(i))}" y="#{y}" fill="#{@muted}" font-size="15" text-anchor="middle">#{esc(clip(l, 14))}</text>)
    end)
  end

  ###
  ### pie
  ###

  defp pie(%{series: [s | _]} = chart) do
    parts = Enum.zip(chart.labels, s.values) |> Enum.map(fn {l, v} -> {l, max(v, 0.0)} end)
    total = parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {cx, cy, r_out, r_in} = {250, 326, 168, 100}

    slices =
      if total <= 0 do
        ""
      else
        {out, _} =
          parts
          |> Enum.with_index()
          |> Enum.map_reduce(-:math.pi() / 2, fn {{_l, v}, i}, start ->
            sweep = v / total * 2 * :math.pi()
            color = colour_at(i)
            {slice(cx, cy, r_out, r_in, start, sweep, color), start + sweep}
          end)

        out
      end

    rows =
      parts
      |> Enum.take(9)
      |> Enum.with_index()
      |> Enum.map(fn {{l, v}, i} ->
        yy = 130 + i * 44
        pct = if total > 0, do: Float.round(v / total * 100, 1), else: 0.0

        ~s(<rect x="520" y="#{yy - 12}" width="14" height="14" rx="4" fill="#{colour_at(i)}"/>) <>
          ~s(<text x="548" y="#{yy}" fill="#{@ink}" font-size="18">#{esc(clip(l, 26))}</text>) <>
          ~s(<text x="#{@width - 44}" y="#{yy}" fill="#{@muted}" font-size="17" text-anchor="end">#{esc(fmt(v, chart))}, #{trim_float(pct)}%</text>)
      end)

    [slices, rows]
  end

  defp pie(_chart), do: ""

  defp colour_at(i), do: Map.fetch!(@tones, Enum.at(@cycle, rem(i, length(@cycle))))

  # A donut segment as one path: outer arc forward, inner arc back. A full circle is split in
  # two, because an SVG arc cannot start and end on the same point.
  defp slice(cx, cy, r_out, r_in, start, sweep, color) when sweep >= @full_turn do
    slice(cx, cy, r_out, r_in, start, :math.pi(), color) <> slice(cx, cy, r_out, r_in, start + :math.pi(), :math.pi(), color)
  end

  defp slice(cx, cy, r_out, r_in, start, sweep, color) do
    stop = start + sweep
    large = if sweep > :math.pi(), do: 1, else: 0
    {x1, y1} = polar(cx, cy, r_out, start)
    {x2, y2} = polar(cx, cy, r_out, stop)
    {x3, y3} = polar(cx, cy, r_in, stop)
    {x4, y4} = polar(cx, cy, r_in, start)

    ~s(<path d="M#{f(x1)},#{f(y1)} A#{r_out},#{r_out} 0 #{large} 1 #{f(x2)},#{f(y2)} L#{f(x3)},#{f(y3)} A#{r_in},#{r_in} 0 #{large} 0 #{f(x4)},#{f(y4)} Z" fill="#{color}" stroke="#{@bg}" stroke-width="3"/>)
  end

  defp polar(cx, cy, r, angle), do: {cx + r * :math.cos(angle), cy + r * :math.sin(angle)}

  ###
  ### numbers and text
  ###

  # Axis values at round steps that cover the data: 0, 50, 100, 150 rather than 0, 37.5, 75.
  defp ticks(lo, hi) when hi - lo < 1.0e-9, do: [0.0, 1.0]

  defp ticks(lo, hi) do
    raw = (hi - lo) / 4
    magnitude = :math.pow(10, Float.floor(:math.log10(raw)))
    step = Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= raw)) * magnitude
    first = Float.floor(lo / step) * step
    last = Float.ceil(hi / step) * step
    count = round((last - first) / step)
    for i <- 0..count, do: first + i * step
  end

  defp fmt(n, %{prefix: prefix, suffix: suffix}), do: prefix <> compact(n) <> suffix

  # An axis reads as one scale: $0.05, $0.10, $0.15 rather than $0.05, $0.1, $0.15. So when any
  # tick has decimals (and none is large enough to be abbreviated) they all get the same count.
  defp tick_label(t, ticks, %{prefix: prefix, suffix: suffix} = chart) do
    small? = Enum.all?(ticks, &(abs(&1) < 1.0e4))
    decimals = ticks |> Enum.map(&decimals/1) |> Enum.max()

    if small? and decimals > 0,
      do: prefix <> :erlang.float_to_binary(t / 1, decimals: decimals) <> suffix,
      else: fmt(t, chart)
  end

  defp decimals(n) do
    rounded = Float.round(n / 1, 2)

    cond do
      rounded == Float.round(rounded, 0) -> 0
      rounded == Float.round(rounded, 1) -> 1
      true -> 2
    end
  end

  defp compact(n) do
    abs = abs(n)

    cond do
      abs >= 1.0e9 -> trim_float(n / 1.0e9) <> "B"
      abs >= 1.0e6 -> trim_float(n / 1.0e6) <> "M"
      abs >= 1.0e4 -> trim_float(n / 1.0e3) <> "K"
      true -> trim_float(n)
    end
  end

  defp trim_float(n) do
    rounded = Float.round(n / 1, 2)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 2])
  end

  defp f(n), do: :erlang.float_to_binary(n / 1, [:compact, decimals: 1])

  # No font metrics here, so width is an estimate; wide enough that the legend and labels never
  # overlap, which is the only thing it is used for.
  defp text_width(text, size), do: String.length(text) * size * 0.56

  defp clip(text, max) do
    text = to_string(text)
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
