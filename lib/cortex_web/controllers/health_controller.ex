defmodule CortexWeb.HealthController do
  @moduledoc "Liveness / readiness probe."
  use CortexWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      "status" => "ok",
      "service" => "cortex",
      "agents" => Enum.map(Cortex.Config.agents(), & &1.name),
      "models" => Enum.map(Cortex.Config.models(), & &1.name)
    })
  end
end
