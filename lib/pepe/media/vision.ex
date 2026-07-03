defmodule Pepe.Media.Vision do
  @moduledoc """
  Policy for turning an inbound image file into something a vision model can see: a byte cap, a
  per-turn parts cap, and the supported-type check (via `Pepe.LLM.Image`). Configured under
  `media.image` in `~/.pepe/config.json`; both limits have sane defaults, so it works unconfigured.

  Deliberately no image *resizing* library. The main image source, Telegram, already delivers each
  photo in several pre-scaled sizes, so the gateway picks the largest that fits the byte cap - no
  libvips/imagemagick dependency, no bloated container. The byte cap is the backstop for any other
  source.
  """

  alias Pepe.Config
  alias Pepe.LLM.Image

  @default_max_mb 5
  @default_max_parts 4

  @doc "Image settings from the config (`media.image`), or `%{}`."
  @spec settings :: map()
  def settings, do: Config.media() |> Map.get("image", %{})

  @doc "Largest inbound image accepted, in bytes (`media.image.max_mb`, default 5 MB)."
  @spec max_bytes :: pos_integer()
  def max_bytes, do: round((settings()["max_mb"] || @default_max_mb) * 1_000_000)

  @doc "How many images one turn may carry (`media.image.max_parts`, default 4). Excess falls back to file paths."
  @spec max_parts :: pos_integer()
  def max_parts, do: settings()["max_parts"] || @default_max_parts

  @doc """
  Load an image file for a vision model. Returns `{:ok, image}`, or `:none` when the file is over
  the byte cap, unreadable, or not a supported image type - in which case the caller falls back to
  handing the agent the file path instead.
  """
  @spec load(String.t()) :: {:ok, Image.t()} | :none
  def load(path) do
    cap = max_bytes()

    with {:ok, %File.Stat{size: size}} when size <= cap <- File.stat(path),
         {:ok, image} <- Image.load(path) do
      {:ok, image}
    else
      _ -> :none
    end
  end
end
