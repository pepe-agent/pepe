defmodule Pepe.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if release_cli?() do
      start_release_cli()
    else
      start_supervisor(maybe_endpoint())
    end
  end

  # Runs while the supervision tree is still up, before it's torn down - the
  # only point where we can still see and wait on in-flight cron jobs. Without
  # this, a job mid-run (agent call, tool side effects, delivery) is just killed
  # with the VM: no record, no delivery, and any side effect it already started
  # (a message sent, a file written) is left half-done with nothing to show for it.
  @impl true
  def prep_stop(state) do
    drain_cron_tasks()
    state
  end

  @cron_drain_timeout_ms 25_000

  defp drain_cron_tasks do
    case Process.whereis(Pepe.Cron.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        case Task.Supervisor.children(Pepe.Cron.TaskSupervisor) do
          [] ->
            :ok

          pids ->
            Logger.info("draining #{length(pids)} in-flight cron job(s) before shutdown")
            deadline = System.monotonic_time(:millisecond) + @cron_drain_timeout_ms
            pids |> Enum.map(&Process.monitor/1) |> await_all_down(deadline)
        end
    end
  end

  defp await_all_down([], _deadline), do: :ok

  defp await_all_down(refs, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("cron drain timed out with #{length(refs)} job(s) still running; shutting down anyway")
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} -> await_all_down(List.delete(refs, ref), deadline)
      after
        remaining -> await_all_down(refs, deadline)
      end
    end
  end

  # Base supervision tree + (optionally) the Phoenix endpoint.
  defp start_supervisor(endpoint_children) do
    # Scheduler utilization is a cumulative counter that has to be switched on before
    # it counts anything - see Pepe.Runtime.Stats.
    Pepe.Runtime.Stats.enable()

    children =
      [
        PepeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:pepe, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Pepe.PubSub},
        # Serializes all config writes so concurrent read-modify-write mutations can't lose each
        # other's changes. Started early: everything below may write config.
        Pepe.Config.Writer,
        # Registry + dynamic supervisor for live agent conversation sessions
        {Registry, keys: :unique, name: Pepe.Agent.Registry},
        Pepe.Agent.SessionSupervisor,
        # In-memory session-scoped tool approvals (the `:session` permission grant)
        Pepe.Permissions.SessionStore,
        # Owns the short-lived cache of secrets fetched from a vault (exec:/file: refs).
        Pepe.Secrets.Vault,
        # MCP tool servers: a registry + dynamic supervisor; clients start on demand.
        {Registry, keys: :unique, name: Pepe.MCP.Registry},
        {DynamicSupervisor, name: Pepe.MCP.DynSup, strategy: :one_for_one},
        # Heartbeat: ephemeral system-events queue + the anti-spam cooldown gate.
        Pepe.Heartbeat.Events,
        Pepe.Heartbeat.Cooldown,
        # Where live TUI/WebSocket sessions register so a fired watch can reach them.
        {Registry, keys: :duplicate, name: Pepe.Watch.Subscribers},
        # Self-healing tracker for permanently-gone Telegram chats.
        Pepe.Gateways.Reachability,
        # Messaging gateways (Telegram, ...). No-ops when not configured.
        Pepe.Gateways.Supervisor,
        # Per-IP rate limiter for the dashboard login (in-memory ETS, no DB).
        PepeWeb.LoginThrottle,
        # Per-session rate limiter for the embeddable chat widget (in-memory ETS, no DB).
        PepeWeb.WidgetThrottle,
        # Per-chat rate limiter for inbound Telegram messages (in-memory ETS, no DB).
        Pepe.Gateways.Telegram.Throttle
      ] ++ endpoint_children ++ scheduler_children() ++ restore_children()

    opts = [strategy: :one_for_one, name: Pepe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # When session persistence is on, re-spawn the saved sessions on boot (off the
  # boot path - the disposable store starts lazily and can be slow).
  defp restore_children do
    if Application.get_env(:pepe, :persist_sessions, false) do
      [
        Supervisor.child_spec({Task, &Pepe.Agent.SessionSupervisor.restore/0},
          id: :session_restore,
          restart: :transient
        )
      ]
    else
      []
    end
  end

  # The scheduled-task timer only runs on the long-lived surfaces (serve/gateway),
  # never during a one-shot CLI command - otherwise `mix pepe run` could fire a
  # cron. Both flags default to false; serve enables the endpoint, gateway the
  # gateways, and either brings up the scheduler.
  defp scheduler_children do
    serve? = Application.get_env(:pepe, :serve_endpoint, false)
    gateways? = Application.get_env(:pepe, :start_gateways, false)
    persist? = Application.get_env(:pepe, :persist_sessions, false)

    # Cron fires only on the server surfaces; watches also run on an interactive
    # console (`tui`/`chat`) so a standalone REPL can fire and deliver its own watches.
    # (Run a single long-lived surface at a time - two schedulers on one config double-fire.)
    crons =
      if serve? or gateways?,
        do: [{Task.Supervisor, name: Pepe.Cron.TaskSupervisor}, Pepe.Cron.Scheduler],
        else: []

    watches = if serve? or gateways? or persist?, do: [Pepe.Watch.Scheduler], else: []
    crons ++ watches
  end

  # The Phoenix endpoint (OpenAI-compatible HTTP API + WebSocket) is only started
  # when serving. CLI one-shot commands set :serve_endpoint to false to boot fast.
  defp maybe_endpoint do
    if Application.get_env(:pepe, :serve_endpoint, true) do
      [PepeWeb.Endpoint]
    else
      []
    end
  end

  ###
  ### release CLI mode (the standalone Burrito binary)
  ###

  # OTP/Burrito releases boot the application automatically. Under `mix` the app
  # is only started by the commands that need it, so this path is release-only.
  #
  # `RELEASE_NAME` is set by the standard `mix release` boot scripts
  # (`bin/RELNAME start`), which Burrito's Zig wrapper doesn't go through - it
  # execs the extracted ERTS directly and sets `__BURRITO=1` instead, so
  # `RELEASE_NAME` is never present in a real packaged binary. Checking it here
  # meant `release_cli?/0` was always false in the shipped binaries: the CLI
  # dispatch never ran, the app booted with the default (endpoint-on)
  # supervision tree, and the process just sat there instead of running the
  # command and exiting.
  defp release_cli?, do: Burrito.Util.running_standalone?()

  # Read the user's argv, start only what the command needs, dispatch, and exit.
  # The spawned fn genuinely never returns (it ends in System.halt/1) - that's the
  # point, not a bug, so silence dialyzer's no_return check for it.
  @dialyzer {:no_return, start_release_cli: 0}
  defp start_release_cli do
    argv = Burrito.Util.Args.argv()
    serve? = serve_command?(argv)

    # Only `serve`/`gateway` bring up the messaging gateways; `run`/`tui` must not.
    Application.put_env(:pepe, :start_gateways, gateways_command?(argv))
    # ...and only those long-running surfaces persist/restore sessions.
    Application.put_env(:pepe, :persist_sessions, gateways_command?(argv))

    # The endpoint must be in the tree at boot, so decide before starting it.
    endpoint_children =
      if serve? do
        enable_endpoint_server()
        [PepeWeb.Endpoint]
      else
        []
      end

    result = start_supervisor(endpoint_children)

    # Run the command off the boot path so `start/2` returns and the node settles.
    # One-shot commands return and we halt; `serve`/`chat`/`gateway` block and the
    # node stays up.
    spawn(fn ->
      Pepe.CLI.main(argv)
      System.halt(0)
    end)

    result
  end

  defp serve_command?(["serve" | _]), do: true
  defp serve_command?(_), do: false

  defp gateways_command?(["serve" | _]), do: true
  defp gateways_command?(["gateway" | _]), do: true
  defp gateways_command?(_), do: false

  defp enable_endpoint_server do
    conf = Application.get_env(:pepe, PepeWeb.Endpoint, [])
    Application.put_env(:pepe, PepeWeb.Endpoint, Keyword.put(conf, :server, true))
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PepeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
