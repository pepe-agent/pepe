defmodule CortexWeb.Router do
  use CortexWeb, :router

  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The /v1 API adds bearer-token auth: open when no tokens exist, scoped once they do.
  pipeline :v1_api do
    plug :accepts, ["json"]
    plug CortexWeb.ApiAuth
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CortexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The web dashboard (LiveView): sessions list + chat.
  scope "/", CortexWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  scope "/", CortexWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/healthz", HealthController, :index
  end

  # OpenAI-compatible API surface.
  scope "/v1", CortexWeb do
    pipe_through :v1_api

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
