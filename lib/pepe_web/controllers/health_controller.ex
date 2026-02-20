defmodule PepeWeb.HealthController do
  @moduledoc "Liveness / readiness probe."
  use PepeWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      "status" => "ok",
      "service" => "pepe",
      "agents" => Enum.map(Pepe.Config.agents(), & &1.name),
      "models" => Enum.map(Pepe.Config.models(), & &1.name)
    })
  end
end
