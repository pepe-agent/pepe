defmodule Pepe.Charts.SvgTest do
  use ExUnit.Case, async: true

  alias Pepe.Charts.Svg

  defp chart(type, overrides \\ %{}) do
    Map.merge(
      %{
        type: type,
        title: "Weekly signups",
        labels: ["Mon", "Tue", "Wed"],
        series: [%{name: "This week", values: [3, 5, 4]}],
        prefix: "",
        suffix: ""
      },
      overrides
    )
  end

  # Well-formed XML is the floor: a converter rejects anything less, and so does a browser.
  defp assert_well_formed(svg) do
    {_doc, _rest} = svg |> String.to_charlist() |> :xmerl_scan.string(quiet: true)
    svg
  end

  test "each type renders a well-formed SVG that carries the title and labels" do
    for type <- [:bar, :line, :pie] do
      svg = type |> chart() |> Svg.render() |> assert_well_formed()
      assert svg =~ "Weekly signups"
      assert svg =~ "Mon"
    end
  end

  test "bars draw one rect per value, the line draws one polyline per series" do
    bars = :bar |> chart() |> Svg.render()
    # Card background + 3 bars + 1 legend-free chart: the background is the only other rect.
    assert Enum.count(Regex.scan(~r/<rect /, bars)) == 4

    two = %{series: [%{name: "A", values: [1, 2, 3]}, %{name: "B", values: [3, 2, 1]}]}
    assert Enum.count(Regex.scan(~r/<polyline /, Svg.render(chart(:line, two)))) == 2
  end

  test "text from the model is escaped, never interpreted as markup" do
    svg = :bar |> chart(%{title: "<script>alert(1)</script> & co", labels: ["a<b", "c", "d"]}) |> Svg.render() |> assert_well_formed()

    refute svg =~ "<script>"
    assert svg =~ "&lt;script&gt;"
    assert svg =~ "&amp; co"
  end

  test "prefix and suffix go around the axis numbers" do
    svg = Svg.render(chart(:bar, %{prefix: "$", suffix: "k"}))
    assert svg =~ "$5k" or svg =~ "$4k"
  end

  test "a pie with a single slice is one closed donut, not a broken arc" do
    svg = :pie |> chart(%{labels: ["All"], series: [%{name: "x", values: [10]}]}) |> Svg.render() |> assert_well_formed()
    assert Enum.count(Regex.scan(~r/<path /, svg)) == 2
  end

  test "all zeros, negatives and a single point do not crash" do
    for values <- [[0, 0, 0], [-2, 4, -1], [7]] do
      labels = Enum.take(["a", "b", "c"], length(values))

      for type <- [:bar, :line, :pie] do
        :bar |> chart(%{type: type, labels: labels, series: [%{name: "s", values: values}]}) |> Svg.render() |> assert_well_formed()
      end
    end
  end

  test "a long series thins its x labels instead of printing them on top of each other" do
    labels = Enum.map(1..40, &"label #{&1}")
    svg = :line |> chart(%{labels: labels, series: [%{name: "s", values: Enum.to_list(1..40)}]}) |> Svg.render()

    shown = Regex.scan(~r/>label \d+</, svg)
    assert Enum.count(shown) < 40
    assert shown != []
  end
end
