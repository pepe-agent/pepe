defmodule PepeWeb.HealthController do
  @moduledoc """
  Liveness / readiness probe. Unauthenticated, so it stays a minimal signal and never
  leaks tenant data: `ready` is true once at least one model connection and one agent
  exist, so the service can actually answer. To discover WHICH agents and models a
  caller can reach (scoped to their project), use the authenticated `GET /v1/models`.
  """
  use PepeWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      "status" => "ok",
      "service" => "pepe",
      "ready" => Pepe.Config.models() != [] and Pepe.Config.agents() != []
    })
  end
end
