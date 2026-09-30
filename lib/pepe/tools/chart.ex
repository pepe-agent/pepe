defmodule Pepe.Tools.Chart do
  @moduledoc """
  Draw a chart and put it in front of the person: a bar, line or pie image, sent to the
  conversation's channel like any attachment.

  The agent supplies the numbers (from a query, a file, a sum it just did); Pepe draws them in
  the dashboard's look (`Pepe.Charts.Svg`) and converts to PNG (`Pepe.Charts.Raster`) so chat
  apps show it inline. Nothing is sent to an outside service. Without an SVG converter on the
  machine the SVG itself is kept and sent, and the result says so.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace
  alias Pepe.Charts.Raster
  alias Pepe.Charts.Svg
  alias Pepe.Tools.SendFile

  @max_points 60
  @max_series 6
  @types ~w(bar line pie)
  @tones ~w(gold teal slate red copper moss)

  @impl true
  def name, do: "chart"

  @impl true
  def spec do
    function(
      "chart",
      "Draw a bar, line or pie chart from numbers you already have and send it to the conversation " <>
        "as an image. Use it when a picture answers better than a table: a trend over time, a " <>
        "comparison between periods or groups, or shares of a whole. Do not invent data; chart " <>
        "what you computed or read. A pie takes exactly one series.",
      %{
        "type" => "object",
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => @types,
            "description" => "bar (comparisons), line (change over time) or pie (shares of a whole)."
          },
          "title" => %{"type" => "string", "description" => "Short title shown on the image."},
          "labels" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "One label per point, e.g. the days or categories. At most #{@max_points}."
          },
          "series" => %{
            "type" => "array",
            "description" => "One or more data series, each with one number per label. At most #{@max_series}.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "values" => %{"type" => "array", "items" => %{"type" => "number"}},
                "tone" => %{
                  "type" => "string",
                  "enum" => @tones,
                  "description" => "Optional color. Leave it out unless the color means something (red for errors)."
                }
              },
              "required" => ["name", "values"]
            }
          },
          "prefix" => %{"type" => "string", "description" => "Put before every number, e.g. \"$\"."},
          "suffix" => %{"type" => "string", "description" => "Put after every number, e.g. \"%\"."},
          "send" => %{"type" => "boolean", "description" => "Send the image to the conversation (default true). False only saves it."}
        },
        "required" => ["type", "labels", "series"]
      }
    )
  end

  @impl true
  def run(args, ctx) do
    with {:ok, chart} <- validate(args),
         {:ok, path, note} <- write(chart, ctx) do
      deliver(path, note, chart, args, ctx)
    end
  end

  ###
  ### input
  ###

  @doc false
  def validate(args) when is_map(args) do
    with {:ok, type} <- type(args["type"]),
         {:ok, labels} <- labels(args["labels"]),
         {:ok, series} <- series(args["series"], length(labels), type) do
      {:ok,
       %{
         type: type,
         title: text(args["title"]),
         labels: labels,
         series: series,
         prefix: short(args["prefix"]),
         suffix: short(args["suffix"])
       }}
    end
  end

  def validate(_), do: {:error, "chart needs `type`, `labels` and `series`"}

  # Literal clauses, not `String.to_existing_atom/1`: the atom may not be loaded yet in a freshly
  # started node, and converting model-supplied text to atoms is not something to lean on anyway.
  defp type("bar"), do: {:ok, :bar}
  defp type("line"), do: {:ok, :line}
  defp type("pie"), do: {:ok, :pie}
  defp type(_), do: {:error, "`type` must be one of: #{Enum.join(@types, ", ")}"}

  defp labels(l) when is_list(l) and l != [] do
    if Enum.count(l) <= @max_points,
      do: {:ok, Enum.map(l, &to_string/1)},
      else: {:error, "too many points: at most #{@max_points} labels"}
  end

  defp labels(_), do: {:error, "`labels` must be a non-empty list"}

  defp series(s, points, type) when is_list(s) and s != [] do
    cond do
      Enum.count(s) > @max_series -> {:error, "too many series: at most #{@max_series}"}
      type == :pie and Enum.count(s) != 1 -> {:error, "a pie chart takes exactly one series"}
      true -> s |> Enum.map(&one_series(&1, points)) |> collect()
    end
  end

  defp series(_, _points, _type), do: {:error, "`series` must be a non-empty list"}

  defp one_series(%{"values" => values} = s, points) when is_list(values) do
    numbers = Enum.map(values, &number/1)

    cond do
      Enum.count(values) != points -> {:error, "series #{inspect(s["name"])} has #{Enum.count(values)} values for #{points} labels"}
      Enum.any?(numbers, &is_nil/1) -> {:error, "series #{inspect(s["name"])} has a value that is not a number"}
      true -> {:ok, %{name: to_string(s["name"] || ""), values: numbers, tone: tone(s["tone"])}}
    end
  end

  defp one_series(_, _points), do: {:error, "each series needs a `name` and a list of `values`"}

  defp collect(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, s} -> s end)}
      error -> error
    end
  end

  defp number(n) when is_number(n), do: n

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp tone("gold"), do: :gold
  defp tone("teal"), do: :teal
  defp tone("slate"), do: :slate
  defp tone("red"), do: :red
  defp tone("copper"), do: :copper
  defp tone("moss"), do: :moss
  defp tone(_), do: nil

  defp text(t) when is_binary(t), do: if(String.trim(t) == "", do: nil, else: String.trim(t))
  defp text(_), do: nil

  defp short(t) when is_binary(t), do: String.slice(t, 0, 4)
  defp short(_), do: ""

  ###
  ### output
  ###

  # Write the PNG when a converter exists, otherwise keep the SVG. Returns the path and a note
  # for the agent when it had to settle for the SVG.
  defp write(chart, ctx) do
    dir = Path.join(Workspace.cwd_in_ctx(ctx), "charts")
    base = "#{slug(chart.title || Atom.to_string(chart.type))}-#{System.system_time(:second)}"
    svg_path = Path.join(dir, base <> ".svg")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(svg_path, Svg.render(chart)) do
      png_path = Path.join(dir, base <> ".png")

      case Raster.to_png(svg_path, png_path) do
        :ok ->
          File.rm(svg_path)
          {:ok, png_path, nil}

        {:error, reason} ->
          {:ok, svg_path, "No PNG was made (#{reason}), so this is an SVG."}
      end
    else
      {:error, reason} -> {:error, "could not write the chart: #{:file.format_error(reason)}"}
    end
  end

  defp deliver(path, note, chart, args, ctx) do
    if args["send"] == false or not is_binary(ctx[:session_key]) do
      {:ok, join(["Chart saved to #{path}.", note])}
    else
      case SendFile.run(%{"path" => path, "caption" => chart.title}, ctx) do
        {:ok, _} ->
          {:ok,
           join([
             "Sent the chart (#{Path.basename(path)}) to the conversation. It is already shown; do not describe it line by line.",
             note
           ])}

        {:error, reason} ->
          {:ok, join(["Chart saved to #{path} but could not be sent: #{reason}", note])}
      end
    end
  end

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "chart"
      s -> s
    end
  end
end
