defmodule PepeWeb.AssetController do
  @moduledoc """
  Serves the static files a plugin package declares in its manifest's `"assets"` list
  (e.g. the built-in chat widget's `widget.js`/`widget.css`). One generic route for
  every package, built-in or user-installed - mirroring how `Pepe.Webhooks` dispatches
  inbound channels, the lookup happens at request time so a freshly-installed plugin
  needs no new route or rebuild.
  """
  use PepeWeb, :controller

  def show(conn, %{"plugin" => plugin, "path" => path_segments}) do
    requested = Enum.join(path_segments, "/")

    case Pepe.Plugins.asset_path(plugin, requested) do
      {:ok, abs_path} ->
        conn
        |> put_resp_content_type(MIME.from_path(abs_path))
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_file(200, abs_path)

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
    end
  end
end
