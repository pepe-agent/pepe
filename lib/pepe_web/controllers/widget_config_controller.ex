defmodule PepeWeb.WidgetConfigController do
  @moduledoc """
  Serves a widget token's dashboard-managed appearance (title/logo/color/theme/
  greeting/position), so `widget.js` can pick it up at load time instead of it being
  baked into the embed snippet's `data-*` attributes - editing the look from the
  dashboard never needs a site redeploy. Cross-origin by nature (the widget's own page
  lives on the customer's site), so the response carries an `access-control-allow-
  origin` matching the token's own `allowed_origin` - the same origin its WebSocket
  connection is already restricted to.
  """
  use PepeWeb, :controller

  alias Pepe.Config

  def show(conn, %{"token" => raw}) do
    case Config.widget_config(raw) do
      nil ->
        conn |> put_status(404) |> json(%{error: "unknown or invalid widget token"})

      config ->
        {origin, fields} = Map.pop(config, :allowed_origin)

        conn
        |> allow_origin(origin)
        |> json(compact(fields))
    end
  end

  def show(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing token"})
  end

  defp allow_origin(conn, origin) when is_binary(origin), do: put_resp_header(conn, "access-control-allow-origin", origin)
  defp allow_origin(conn, _origin), do: conn

  defp compact(fields), do: fields |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
