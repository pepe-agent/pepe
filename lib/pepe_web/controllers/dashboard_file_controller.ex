defmodule PepeWeb.DashboardFileController do
  @moduledoc """
  Serves a file an agent produced for a dashboard ("web:<id>") chat, via the
  time-boxed token `Pepe.Tools.SendFile` registers in `Pepe.Store` under the
  `:dashboard_download` namespace. Gated by `PepeWeb.Auth`'s plug (same gate every
  other dashboard route uses), so a guessed or leaked link is still no better than
  a stolen dashboard session.
  """
  use PepeWeb, :controller

  def show(conn, %{"token" => token}) do
    case Pepe.Store.get(:dashboard_download, token) do
      %{path: path, filename: filename} when is_binary(path) ->
        if File.regular?(path) do
          send_download(conn, {:file, path}, filename: filename)
        else
          conn |> put_status(:not_found) |> text("That file is no longer on disk.")
        end

      _ ->
        conn |> put_status(:not_found) |> text("This download link has expired or doesn't exist.")
    end
  end
end
