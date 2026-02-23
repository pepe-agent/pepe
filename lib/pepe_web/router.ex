defmodule PepeWeb.Router do
  use PepeWeb, :router

  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The /v1 API adds bearer-token auth: open when no tokens exist, scoped once they do.
  pipeline :v1_api do
    plug :accepts, ["json"]
    plug PepeWeb.ApiAuth
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PepeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", PepeWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/healthz", HealthController, :index
  end

  # Inbound webhook channels (WhatsApp, ...). One route, dispatched by provider.
  # GET = verification handshake; POST = an inbound event. No CSRF (external caller).
  scope "/webhooks", PepeWeb do
    pipe_through :api

    get "/:company/:provider/:slug", WebhookController, :verify
    post "/:company/:provider/:slug", WebhookController, :receive
  end

  # The web dashboard. Each section is a clean path; a specific conversation adds
  # `?chat=<key>` (session keys carry ":", so they ride in the query). The section is
  # carried by the live_action.
  scope "/", PepeWeb do
    pipe_through :browser

    # One on_mount hook applies the configured locale to every dashboard LiveView, so
    # no LiveView repeats Config.put_locale/0 in its mount.
    live_session :dashboard, on_mount: {PepeWeb.LiveLocale, :default} do
      live "/", ChatLive
      live "/chat", ChatLive
      live "/companies", CompaniesLive
      live "/agents", AgentsLive
      live "/models", ModelsLive
      live "/bots", ChannelsLive
      live "/cron", ScheduledLive
      live "/watches", WatchesLive
      live "/learn", LearningLive
      live "/usage", UsageLive
      live "/mcp", ToolServersLive
      live "/config", ConfigLive
    end
  end

  # OpenAI-compatible API surface.
  scope "/v1", PepeWeb do
    pipe_through :v1_api

    get "/models", OpenAIController, :models
    post "/chat/completions", OpenAIController, :chat_completions
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:pepe, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: PepeWeb.Telemetry
    end
  end
end
