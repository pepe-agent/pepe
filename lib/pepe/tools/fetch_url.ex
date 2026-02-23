defmodule Pepe.Tools.FetchUrl do
  @moduledoc "Fetch a URL over HTTP(S) and return the response body."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "fetch_url"

  @impl true
  def spec do
    function("fetch_url", "Perform an HTTP GET and return the (text) response body.", %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to fetch."}
      },
      "required" => ["url"]
    })
  end

  @impl true
  def run(%{"url" => url}, _ctx) do
    case Req.get(url, receive_timeout: 30_000, retry: :transient) do
      {:ok, %{status: status, body: body}} ->
        {:ok, "status=#{status}\n#{truncate(stringify(body))}"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  def run(_, _), do: {:error, "missing 'url'"}

  defp stringify(body) when is_binary(body), do: body
  defp stringify(body), do: inspect(body)

  defp truncate(text, max \\ 30_000) do
    if byte_size(text) > max, do: binary_part(text, 0, max) <> "\n...(truncated)", else: text
  end
end
