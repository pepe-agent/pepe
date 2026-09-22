defmodule Pepe.LLM.Image do
  @moduledoc """
  An inbound image on its way to a vision-capable model. Loaded from a file into a neutral
  `%{media_type, data}` shape (base64), then rendered per provider by the adapters: OpenAI-style
  `image_url` data URIs, Anthropic `image` source blocks, Responses `input_image`.

  Kept ephemeral on purpose - an image rides in the call `opts` for the turn it arrives, never into
  the persisted history. Like voice and documents, the record of it is the model's own reply, not the
  bytes (which would bloat every session file and be re-sent every turn). See the gateways.
  """

  @type t :: %{media_type: String.t(), data: String.t()}

  # Providers accept these; anything else we don't claim to know.
  @by_ext %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc "Load an image file into `{:ok, %{media_type, data}}`, or `{:error, reason}`."
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, media_type} <- media_type(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, %{media_type: media_type, data: Base.encode64(bytes)}}
    end
  end

  @doc "A `data:` URI for the OpenAI / Responses `image_url` shape."
  @spec data_uri(t()) :: String.t()
  def data_uri(%{media_type: mt, data: data}), do: "data:" <> mt <> ";base64," <> data

  defp media_type(path) do
    case Map.get(@by_ext, path |> Path.extname() |> String.downcase()) do
      nil -> {:error, :unsupported_image_type}
      mt -> {:ok, mt}
    end
  end
end
