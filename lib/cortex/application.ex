defmodule Cortex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if release_cli?() do
      start_release_cli()
    else
      start_supervisor(maybe_endpoint())
    end
  end

  # Base supervision tree + (optionally) the Phoenix endpoint.
  defp start_supervisor(endpoint_children) do
    children =
      [
        CortexWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:cortex, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cortex.PubSub},
        # Registry + dynamic supervisor for live agent conversation sessions
        {Registry, keys: :unique, name: Cortex.Agent.Registry},
        Cortex.Agent.SessionSupervisor,
        # In-memory session-scoped tool approvals (the `:session` permission grant)
        Cortex.Permissions.SessionStore,
        # Messaging gateways (Telegram, ...). No-ops when not configured.
        Cortex.Gateways.Supervisor
      ] ++ endpoint_children

    opts = [strategy: :one_for_one, name: Cortex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The Phoenix endpoint (OpenAI-compatible HTTP API + WebSocket) is only started
  # when serving. CLI one-shot commands set :serve_endpoint to false to boot fast.
  defp maybe_endpoint do
    if Application.get_env(:cortex, :serve_endpoint, true) do
      [CortexWeb.Endpoint]
    else
      []
    end
  end

  ###
  ### release CLI mode (the standalone Burrito binary)
  ###

  # OTP/Burrito releases boot the application automatically. Under `mix` the app
  # is only started by the commands that need it, so this path is release-only.
  defp release_cli?, do: System.get_env("RELEASE_NAME") != nil

  # Read the user's argv, start only what the command needs, dispatch, and exit.
  defp start_release_cli do
    argv = Burrito.Util.Args.argv()
    serve? = serve_command?(argv)

    # The endpoint must be in the tree at boot, so decide before starting it.
    endpoint_children =
      if serve? do
        enable_endpoint_server()
        [CortexWeb.Endpoint]
      else
        []
      end

    result = start_supervisor(endpoint_children)

    # Run the command off the boot path so `start/2` returns and the node settles.
    # One-shot commands return and we halt; `serve`/`chat`/`gateway` block and the
    # node stays up.
    spawn(fn ->
      Cortex.CLI.main(argv)
      System.halt(0)
    end)

    result
  end

  defp serve_command?(["serve" | _]), do: true
  defp serve_command?(_), do: false

  defp enable_endpoint_server do
    conf = Application.get_env(:cortex, CortexWeb.Endpoint, [])
    Application.put_env(:cortex, CortexWeb.Endpoint, Keyword.put(conf, :server, true))
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CortexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
