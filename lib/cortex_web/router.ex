defmodule CortexWeb.Router do
  use CortexWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CortexWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/healthz", HealthController, :index
  end

  # OpenAI-compatible API surface.
  scope "/v1", CortexWeb do
    pipe_through :api

    get "/models", OpenAIController, :models
    post "/chat/completions", OpenAIController, :chat_completions
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:cortex, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: CortexWeb.Telemetry
    end
  end
end
