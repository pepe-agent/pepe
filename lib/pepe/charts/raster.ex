defmodule Pepe.Charts.Raster do
  @moduledoc """
  Turns a chart's SVG into a PNG, which is what a chat app shows inline (Telegram and WhatsApp
  will not draw an SVG).

  Uses whichever converter the machine already has: `rsvg-convert` (librsvg) first, then
  ImageMagick (`magick`, or the older `convert`). Pepe does not ship one; the `-full` Docker
  image has ImageMagick. With none installed `to_png/2` says so, and the caller keeps the SVG.
  """

  @timeout_ms 30_000

  @doc "Whether some converter is installed."
  @spec available?() :: boolean()
  def available?, do: converter() != nil

  @doc "Convert `svg_path` into a PNG at `png_path`, twice the SVG's size so it stays sharp on a phone."
  @spec to_png(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def to_png(svg_path, png_path) do
    case converter() do
      nil -> {:error, "no SVG converter installed (rsvg-convert or ImageMagick)"}
      {exe, args} -> run(exe, args.(svg_path, png_path), png_path)
    end
  end

  defp converter do
    cond do
      exe = System.find_executable("rsvg-convert") -> {exe, fn svg, png -> ["--zoom", "2", "--output", png, svg] end}
      exe = System.find_executable("magick") -> {exe, &magick_args/2}
      exe = System.find_executable("convert") -> {exe, &magick_args/2}
      true -> nil
    end
  end

  defp magick_args(svg, png), do: ["-background", "none", "-density", "192", svg, png]

  defp run(exe, args, png_path) do
    task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} -> if File.exists?(png_path), do: :ok, else: {:error, "the converter produced no file"}
      {:ok, {out, code}} -> {:error, "converter exited #{code}: #{String.slice(out, 0, 200)}"}
      _ -> {:error, "the converter took too long"}
    end
  end
end
