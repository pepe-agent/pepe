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
    # Fail-closed: without a dashboard password, only genuine loopback clients get in.
    plug PepeWeb.NetworkGuard
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

    get "/:project/:provider/:slug", WebhookController, :verify
    post "/:project/:provider/:slug", WebhookController, :receive
  end

  # The chat widget's dashboard-managed appearance - must come before the generic
  # asset route below, or "config" would be looked up as a static file and 404.
  scope "/plugin-assets/pepe-widget", PepeWeb do
    pipe_through :api

    get "/config", WidgetConfigController, :show
  end

  # Static assets a plugin package declares (e.g. the built-in chat widget's JS/CSS).
  # One route for every package, resolved at request time - see Pepe.Plugins.asset_path/2.
  scope "/plugin-assets", PepeWeb do
    pipe_through :api

    get "/:plugin/*path", AssetController, :show
  end

  # The web dashboard. Each section is a clean path; a specific conversation adds
  # `?chat=<key>` (session keys carry ":", so they ride in the query). The section is
  # carried by the live_action.
  scope "/", PepeWeb do
    pipe_through :browser

    # Dashboard sign-in (only enforced when a dashboard password is configured).
    get "/login", LoginController, :new
    post "/login", LoginController, :create
    delete "/logout", LoginController, :delete

    # Two on_mount hooks: apply the configured locale, and gate on the dashboard
    # password (a no-op when none is set).
    live_session :dashboard,
      on_mount: [{PepeWeb.LiveLocale, :default}, {PepeWeb.Auth, :ensure}] do
      live "/", OverviewLive
      live "/overview", OverviewLive
      live "/chat", ChatLive
      live "/projects", ProjectsLive
      live "/agents", AgentsLive
      live "/models", ModelsLive
      live "/bots", ChannelsLive
      live "/integrations", IntegrationsLive
      live "/cron", ScheduledLive
      live "/watches", WatchesLive
      live "/learn", LearningLive
      live "/usage", UsageLive
      live "/traces", TracesLive
      live "/mcp", ToolServersLive
      live "/plugins", PluginsLive
      live "/hooks", HooksLive
      live "/tokens", TokensLive
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
