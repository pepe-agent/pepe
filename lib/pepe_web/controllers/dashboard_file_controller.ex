defmodule PepeWeb.DashboardFileController do
  @moduledoc """
  Serves a file an agent produced for a dashboard ("web:<id>") chat, from the copy
  `Pepe.Tools.SendFile` kept in `Pepe.ChatFiles` under a random token. The link works for
  as long as the conversation exists. Gated by `PepeWeb.Auth`'s plug (same gate every
  other dashboard route uses), so a guessed or leaked link is still no better than
  a stolen dashboard session.
  """
  use PepeWeb, :controller

  def show(conn, %{"token" => token}) do
    case Pepe.ChatFiles.find(token) do
      {:ok, %{path: path, filename: filename}} ->
        send_download(conn, {:file, path}, filename: filename)

      :error ->
        conn |> put_status(:not_found) |> text("This download link has expired or doesn't exist.")
    end
  end
end
