defmodule Mix.Tasks.Pepe do
  @shortdoc "Pepe CLI - manage agents & model connections, run, chat, serve"
  @moduledoc """
  Pepe command-line interface.

  Create model connections, define agents, run one-shot prompts, chat
  interactively, expose the OpenAI-compatible HTTP API + WebSocket, and run the
  Telegram gateway.

  ## Model connections

      mix pepe model                                        # show current + switch/add (easiest)

      # guided: pick a provider -> auth method -> model
      mix pepe model add NAME [--default]
      # or fully manual:
      mix pepe model add NAME --base-url URL --api-key KEY [--model ID] [--default]

      mix pepe model providers                              # list known providers
      mix pepe model models --base-url URL --api-key KEY    # list a provider's models
      mix pepe model list                                   # list saved connections
      mix pepe model test [NAME]                            # ping a connection to verify it works
      mix pepe model remove NAME
      mix pepe model default NAME

  ## Companies (multi-tenant)

  Optional. Without `--company`, everything operates on the **root** scope, exactly
  as a single-tenant install always has. Add a company to isolate a tenant: its
  agents, workspaces, `shared/` space, models and routing are walled off from every
  other company. Add `--company NAME` to any agent/model command to act inside it.

      mix pepe company add NAME [--description "..."]
      mix pepe company list
      mix pepe company remove NAME [--force]   # --force also drops its agents

  ## API access tokens

  Bearer tokens for the `/v1` HTTP API and the WebSocket. With no tokens, only
  same-machine (loopback) callers reach either; creating the first one locks both -
  every call, local or remote, then needs a valid token. Scope a token to a company
  (`--company`) or a single agent (`--agent HANDLE`).

      mix pepe token add [--company CO] [--agent HANDLE] [--label "..."]
      mix pepe token add --agent HANDLE --widget --allowed-origin https://example.com
      mix pepe token list
      mix pepe token update ID [--title ...] [--greeting ...] ...
      mix pepe token revoke ID

  `--widget` mints a token meant to sit in public page source (an embedded chat
  widget's script tag), so it must be `--agent`-locked. `--allowed-origin` registers
  the browser origin (scheme+host) the WebSocket accepts it from. Optional
  appearance (`--title`/`--logo`/`--color`/`--theme`/`--greeting`/`--position`) on
  `add` or later `update` is fetched by the widget script at load time, so it never
  needs to be baked into the embed snippet.

  ## Watches (one-shot "notify me when X")

  A watch polls a cheap probe and notifies **once** when it passes, then stops -
  durable across restarts. Agent-judged watches are created from chat (the `watch`
  tool); the CLI creates probe watches.

      mix pepe watch add "site up" --probe "curl -sf https://x" [--message "..."] [--every 120] [--deliver telegram:<chat>]
      mix pepe watch list
      mix pepe watch pause ID | resume ID | cancel ID

  ## Agents

      mix pepe agent add NAME --model MODEL --prompt "..." --tools bash,read_file [--can-message b,c] [--can-manage x,y|*|none] [--admin] [--default] [--company CO]
      mix pepe agent list [--company CO | --all]
      mix pepe agent route FROM TO [--remove] [--company CO]   # let FROM message TO (directed)
      mix pepe agent manage ADMIN TARGET [--remove]  # let ADMIN administer TARGET ("*" = all)
      mix pepe agent rename OLD NEW          # rename + move its workspace dir
      mix pepe agent remove NAME
      mix pepe agent default NAME

  ## Running

      mix pepe run [AGENT] "your prompt"      # one-shot, streams to stdout
      mix pepe goal "OBJECTIVE" --criteria "how we know it's done" [--max-attempts N] [--judge MODEL] [--agent NAME]
                                               # work until an independent reviewer says the criterion is met
      mix pepe tui [AGENT | --agent NAME] [--session KEY]   # interactive console, keeps the session (alias: chat)
      mix pepe serve [--port 4000]             # OpenAI API + WebSocket server
      mix pepe gateway telegram setup          # configure the default Telegram bot
      mix pepe gateway telegram add NAME --token T [--agent A] [--trainers id1,id2|none]
                                          [--heartbeat-minutes N] [--heartbeat-hours 8-22]
                                          [--progress reaction|ambient|off|verbose]
      mix pepe gateway telegram list           # list configured bots
      mix pepe gateway telegram remove NAME    # delete a named bot
      mix pepe gateway telegram                # run the gateway (one poller per bot)

  ## Misc

      mix pepe tools                           # list built-in tools
      mix pepe timelearn [AGENT]               # what the agent has learned, on a timeline
      mix pepe learn consolidate|auto [AGENT]    # tidy memory now, or schedule nightly consolidation
      mix pepe cron list|add|run|logs ...        # scheduled tasks (recurring agent jobs)
      mix pepe usage [--company CO] ...          # token usage & cost by cycle (billing)
      mix pepe usage export --company CO ...     # generate a client invoice (md/csv)
      mix pepe usage prices [--refresh]        # show/refresh the live model price cache
      mix pepe traces [--company CO] [ID]        # inspect/replay recent agent runs
      mix pepe plugin list|install|remove ...     # user plugins (tools/channels) loaded at runtime
      mix pepe migrate SOURCE [--dry-run]         # import models/agents from another runtime
      mix pepe eval [SUITE]                     # run an agent eval suite
      mix pepe mcp add|list|tools|remove ...      # external tool servers (MCP: Sentry, GitHub, ...)
      mix pepe doctor [--offline]              # health-check the whole setup
      mix pepe review [approve|reject ID]      # approve/reject autonomous writes staged for review
      mix pepe version                         # what's running, and which build
      mix pepe update                          # self-update the binary to the latest release
      mix pepe setup                           # guided setup: model, agent, channels, plugins, migrate, dashboard
      mix pepe config                          # show config path + summary
      mix pepe backup [--output FILE.tgz]      # archive ~/.pepe + list the secret env vars to save
  """
  use Mix.Task
  use Gettext, backend: Pepe.Gettext

  alias Pepe.Company
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @impl true
  def run(argv) do
    # Ensure the project is compiled (mix tasks don't recompile by default).
    Mix.Task.run("compile", ["--no-deps-check"])
    apply_locale()
    dispatch(argv)
  end

  # Apply the language chosen at setup so every CLI string Pepe emits (prompts,
  # menu hints, confirmations) comes out in it. Best-effort: a missing/unreadable
  # config just leaves the default (en). Called by both entry points (this task
  # and Pepe.CLI for the escript/release).
  @doc false
  def apply_locale do
    Config.put_locale()
  catch
    _, _ -> :ok
  end

  @doc """
  Dispatch a parsed `argv` to the matching command. Shared by the `mix pepe`
  task and the standalone `pepe` escript (`Pepe.CLI`), so both entry points
  behave identically. The escript calls this directly (no Mix at runtime).
  """
  def dispatch([]), do: help()
  def dispatch(["help"]), do: help()

  # `pepe help <group>` mirrors `pepe <group> help`.
  def dispatch(["help", "agent" | _]), do: agent_cmd(["help"])
  def dispatch(["help", "model" | _]), do: model_cmd(["help"])
  def dispatch(["help", "gateway" | _]), do: gateway_cmd(["help"])
  def dispatch(["help", "company" | _]), do: company_cmd(["help"])
  def dispatch(["help", "serve" | _]), do: serve_help()
  def dispatch(["help", "run" | _]), do: run_help()
  def dispatch(["help", "backup" | _]), do: backup_help()

  def dispatch(["setup" | _]), do: with_config(&setup/0)
  def dispatch(["config" | rest]), do: with_config(fn -> config_cmd(rest) end)
  def dispatch(["dashboard" | rest]), do: with_config(fn -> dashboard_cmd(rest) end)
  def dispatch(["backup", "help" | _]), do: backup_help()
  def dispatch(["backup" | rest]), do: with_config(fn -> backup_cmd(rest) end)
  def dispatch(["tools" | _]), do: with_config(&tools/0)
  def dispatch(["timelearn" | rest]), do: with_config(fn -> timelearn_cmd(rest) end)

  # `learn consolidate` calls the model (needs the app); `auto`/`status` only read
  # and write config.
  def dispatch(["learn", "consolidate" | rest]),
    do: with_app([], fn -> learn_cmd(["consolidate" | rest]) end)

  def dispatch(["learn" | rest]), do: with_config(fn -> learn_cmd(rest) end)

  # `cron list/history` only read files; `cron run` needs the full app to call
  # the model, so route everything through with_app.
  def dispatch(["cron", sub | rest]) when sub in ["list", "history", "logs"],
    do: with_config(fn -> cron_cmd([sub | rest]) end)

  def dispatch(["cron" | rest]), do: with_app([], fn -> cron_cmd(rest) end)
  def dispatch(["doctor" | rest]), do: with_app([], fn -> doctor_cmd(rest) end)
  def dispatch(["review" | rest]), do: with_app([], fn -> review_cmd(rest) end)
  def dispatch(["update" | _]), do: with_app([], fn -> update_cmd() end)

  # Answering "what am I running?" needs no config, no app, and no network: it is the one
  # question a broken install still has to be able to answer, and the first one support
  # will ask.
  def dispatch([v | _]) when v in ["version", "--version", "-v"], do: version_cmd()

  # `mcp tools` launches the server (needs the app); the rest just edit config.
  def dispatch(["mcp", "tools" | rest]), do: with_app([], fn -> mcp_cmd(["tools" | rest]) end)
  def dispatch(["mcp" | rest]), do: with_config(fn -> mcp_cmd(rest) end)

  # `usage prices --refresh` fetches over the network (needs Req/the app);
  # reporting just reads the ledger files.
  def dispatch(["usage", "prices" | rest]),
    do: with_app([], fn -> usage_cmd(["prices" | rest]) end)

  def dispatch(["usage" | rest]), do: with_config(fn -> usage_cmd(rest) end)
  def dispatch(["traces" | rest]), do: with_config(fn -> traces_cmd(rest) end)

  # `plugin install`/`scan` may fetch a URL (needs Req); list/remove only touch files.
  def dispatch(["plugin", sub | rest]) when sub in ["install", "scan"],
    do: with_app([], fn -> plugin_cmd([sub | rest]) end)

  def dispatch(["plugin" | rest]), do: with_config(fn -> plugin_cmd(rest) end)
  def dispatch(["migrate" | rest]), do: with_config(fn -> migrate_cmd(rest) end)
  def dispatch(["company" | rest]), do: with_config(fn -> company_cmd(rest) end)

  # `hooks generate` calls a model (needs the app); `list` just reads.
  def dispatch(["hooks", "generate" | rest]),
    do: with_app([], fn -> hooks_cmd(["generate" | rest]) end)

  def dispatch(["hooks" | rest]), do: with_config(fn -> hooks_cmd(rest) end)
  def dispatch(["eval" | rest]), do: with_app([], fn -> eval_cmd(rest) end)
  def dispatch(["token" | rest]), do: with_config(fn -> token_cmd(rest) end)
  def dispatch(["watch" | rest]), do: with_config(fn -> watch_cmd(rest) end)
  def dispatch(["model" | rest]), do: with_config(fn -> model_cmd(rest) end)
  def dispatch(["agent" | rest]), do: with_config(fn -> agent_cmd(rest) end)
  def dispatch(["run", "help" | _]), do: run_help()
  def dispatch(["run" | rest]), do: with_app([], fn -> run_cmd(rest) end)
  def dispatch(["goal" | rest]), do: with_app([persist: true], fn -> goal_cmd(rest) end)
  def dispatch(["chat" | rest]), do: with_app([persist: true], fn -> tui_cmd(rest) end)
  def dispatch(["tui" | rest]), do: with_app([persist: true], fn -> tui_cmd(rest) end)

  def dispatch(["serve", "help" | _]), do: serve_help()

  def dispatch(["serve", sub | rest]) when sub in ["install", "uninstall", "status"],
    do: with_config(fn -> serve_service_cmd(sub, rest) end)

  def dispatch(["serve" | rest]),
    do: with_app([serve: true, gateways: true, port: serve_port(rest)], fn -> serve_cmd(rest) end)

  # Configuring a gateway only touches the config file - no app needed.
  def dispatch(["gateway", "telegram", "setup" | _]), do: with_config(&telegram_setup/0)

  def dispatch(["gateway", "telegram", sub | rest]) when sub in ["add", "remove", "list"],
    do: with_config(fn -> gateway_cmd(["telegram", sub | rest]) end)

  # WhatsApp connections are webhook-based - served by `mix pepe serve`, so the
  # CLI just edits config (no running poller).
  def dispatch(["gateway", "whatsapp" | rest]),
    do: with_config(fn -> gateway_cmd(["whatsapp" | rest]) end)

  def dispatch(["gateway" | rest]), do: with_app([gateways: true], fn -> gateway_cmd(rest) end)

  def dispatch(other) do
    error("unknown command: #{Enum.join(other, " ")}\n")
    help()
  end

  ###
  ### bootstrapping
  ###

  # Config-only commands: just need Jason + File IO.
  defp with_config(fun) do
    {:ok, _} = Application.ensure_all_started(:jason)
    fun.()
  end

  # Commands that talk to a model / serve: start the full OTP app. `opts` decides
  # what to bring up - `serve: true` opens the HTTP endpoint, `gateways: true`
  # starts the messaging gateways (Telegram). Local `run`/`tui` pass neither.
  defp with_app(opts, fun) do
    serve? = Keyword.get(opts, :serve, false)
    gateways? = Keyword.get(opts, :gateways, false)
    Application.put_env(:pepe, :serve_endpoint, serve?)
    Application.put_env(:pepe, :start_gateways, gateways?)
    # Persist sessions for any keyed surface so they survive a restart and show in
    # the dashboard (serve/gateway, and the console which holds a session too).
    Application.put_env(
      :pepe,
      :persist_sessions,
      serve? or gateways? or Keyword.get(opts, :persist, false)
    )

    if serve? do
      # Phoenix only opens the HTTP listener when the endpoint is told to serve; set
      # the port here (before boot) so `--port` / $PORT actually takes effect.
      conf = Application.get_env(:pepe, PepeWeb.Endpoint, [])
      http = conf |> Keyword.get(:http, []) |> Keyword.put(:port, Keyword.get(opts, :port, 4000))

      Application.put_env(
        :pepe,
        PepeWeb.Endpoint,
        conf |> Keyword.put(:server, true) |> Keyword.put(:http, http)
      )
    end

    {:ok, _} = Application.ensure_all_started(:pepe)
    fun.()
  end

  # Resolve the serve port: `--port N`, else $PORT, else 4000.
  defp serve_port(rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [port: :integer])

    cond do
      opts[:port] -> opts[:port]
      System.get_env("PORT") -> String.to_integer(System.get_env("PORT"))
      true -> 4000
    end
  end

  ###
  ### model
  ###

  # `mix pepe model` (no subcommand): the friendly entry point - show the current
  # default and either switch among saved connections or start the add wizard.
  defp model_cmd([]) do
    case Config.models() do
      [] ->
        info("No model connections yet. Let's add one.")
        add_model_interactively()

      models ->
        default = Config.default_model_name()

        chosen =
          Pepe.TUI.select([:__add__ | models],
            label: bold("Switch default model") <> dim(" (current: #{default || "none"})"),
            render_as: fn
              :__add__ ->
                dim("+ add a new connection")

              m ->
                mark = if m.name == default, do: dim(" <- current"), else: ""
                [m.name, dim("  (#{m.model})"), mark]
            end
          )

        case chosen do
          :__add__ ->
            add_model_interactively()

          m ->
            Config.set_default_model(m.name)
            ok("default model -> #{m.name}")
        end
    end
  end

  # NAME is optional on the command line: if it's missing (or the first token
  # is actually a flag, e.g. `model add --base-url ...`), prompt for it the
  # same way an omitted --model id falls through to an interactive picker.
  defp model_cmd(["add" | rest]) do
    case rest do
      [maybe_name | flags] ->
        if String.starts_with?(maybe_name, "-") do
          # prompt_name/0 already resolved uniqueness (replace-or-rename), so
          # model_add's own auto-rename-on-collision would be redundant here.
          model_add(prompt_name(), rest, false)
        else
          model_add(maybe_name, flags)
        end

      [] ->
        model_add(prompt_name(), [], false)
    end
  end

  defp model_cmd(["providers" | _]) do
    info("known providers (pick one with `mix pepe model add NAME`):")

    Pepe.Providers.all()
    |> Enum.each(fn p ->
      key = p.env || "no key"
      puts("  #{bold(p.label)}\n    base-url: #{p.base_url || "(custom)"}  ·  key: #{key}")
    end)
  end

  defp model_cmd(["models" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [base_url: :string, api_key: :string])
    base_url = opts[:base_url] || "https://api.openai.com/v1"

    case fetch_models(base_url, opts[:api_key]) do
      {:ok, ids} ->
        info("#{length(ids)} models at #{base_url}:")
        Enum.each(ids, &puts("  #{&1}"))

      {:error, reason} ->
        error("could not fetch models: #{describe(reason)}")
    end
  end

  defp model_cmd(["list" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string, all: :boolean])
    default = Config.default_model_name()

    models =
      if opts[:all],
        do: Config.models(),
        else: Enum.filter(Config.models(), &(Company.of(&1.name) == opts[:company]))

    case models do
      [] ->
        info("no model connections. add one:\n  mix pepe model add openrouter --api-key '${OPENROUTER_API_KEY}' --model openai/gpt-5-chat")

      models ->
        Enum.each(models, &print_model_line(&1, default))
    end
  end

  defp model_cmd(["remove", name | _]) do
    if Config.get_model(name) do
      Config.delete_model(name)
      ok("removed model connection #{name}")
    else
      error("unknown model connection: #{name}")
    end
  end

  defp model_cmd(["rename", old, new | _]) do
    case Config.rename_model(old, new) do
      :ok ->
        ok("model connection #{green(old)} -> #{green(new)} (every agent, cron and default pointing at it still resolves correctly)")

      {:error, :not_found} ->
        error("unknown model connection: #{old}")

      {:error, :already_exists} ->
        error("a model connection named #{new} already exists")

      {:error, :scope_mismatch} ->
        error("can't rename across a company boundary")
    end
  end

  defp model_cmd(["default", name | _]) do
    # Validate first. Pointing the default at a name that does not exist leaves an install
    # that looks configured and answers nothing, and only `doctor` ever says why.
    if Config.get_model(name) do
      Config.set_default_model(name)
      ok("default model -> #{name}")
    else
      error("unknown model connection: #{name}")
    end
  end

  # Redo the OAuth sign-in in place - same name, same base_url/model/pricing/
  # fallbacks/etc., only the access+refresh token is replaced. For when the
  # refresh token itself died (not just expired) and ensure_fresh/1's silent
  # refresh-grant can't recover it.
  defp model_cmd(["reconnect", name | _]) do
    info("reconnecting #{bold(name)} - your browser will open to sign in again...")

    case Pepe.OAuth.reconnect(name) do
      {:ok, _model} ->
        ok("#{green(name)} reconnected - new token saved, nothing else on the connection changed")

      {:error, :not_found} ->
        error("unknown model connection: #{name}")

      {:error, :not_oauth} ->
        error("#{name} is a plain API-key connection, not a subscription sign-in - nothing to reconnect")

      {:error, :unsupported_provider} ->
        error("#{name}'s provider has no subscription sign-in flow registered")

      {:error, reason} ->
        error("reconnect failed: #{describe(reason)}")
    end
  end

  # Preflight: send a tiny real request to confirm the connection works.
  defp model_cmd(["test" | rest]) do
    name = List.first(rest) || Config.default_model_name()

    case name && Config.get_model(name) do
      nil ->
        error("unknown model connection: #{inspect(name)}")

      model ->
        {:ok, _} = Application.ensure_all_started(:req)
        info("pinging #{bold(name)} (#{model.model})...")

        case Pepe.LLM.chat(model, [%{"role" => "user", "content" => "Reply with exactly: pong"}], max_tokens: 64) do
          {:ok, res} ->
            ok("#{green(name)} works - reply: #{String.slice(res.content || "", 0, 60)}")

          {:error, reason} ->
            error("#{name} failed: #{describe(reason)}")
        end
    end
  end

  defp model_cmd(["help"]) do
    info("""
    mix pepe model - manage model connections

      (no args)                              show default + switch/add interactively
      add NAME [--base-url URL --api-key KEY --model ID] [--default]
      providers                              list known providers
      models --base-url URL --api-key KEY    list a provider's models
      list                                   list saved connections
      test [NAME]                            ping a connection
      reconnect NAME                         redo a subscription sign-in (same connection, new token)
      remove NAME
      rename OLD NEW                         rename it, updating every reference
      default NAME                           set the default model
    """)
  end

  defp model_cmd(_),
    do: error("usage: mix pepe model [add|list|models|providers|test|reconnect|remove|rename|default] (or: help)")

  defp print_model_line(m, default) do
    mark = if m.name == default, do: " #{green("(default)")}", else: ""
    puts("#{bold(m.name)}#{mark}\n  url:   #{m.base_url}\n  model: #{m.model}\n  api:   #{m.api}")
  end

  defp add_model_interactively, do: model_add(prompt_name(), ["--default"], false)

  defp prompt_name do
    Owl.IO.input(label: "Name for this connection:")
    |> ensure_unique(model_names(), "model connection")
  end

  # Auto-renames on collision instead of silently overwriting: "openrouter"
  # once taken becomes "openrouter-2", "openrouter-3", ... The bare `name` is
  # kept around for provider auto-detection (matching e.g. the "openrouter"
  # catalog entry); only the stored handle gets suffixed.
  defp unique_handle(name, company) do
    taken = model_names()
    handle = Company.handle(company, name)

    if handle in taken do
      2
      |> Stream.iterate(&(&1 + 1))
      |> Enum.find_value(&candidate_handle(&1, name, company, taken))
    else
      {name, handle}
    end
  end

  defp candidate_handle(n, name, company, taken) do
    candidate = "#{name}-#{n}"
    h = Company.handle(company, candidate)
    if h not in taken, do: {candidate, h}
  end

  # dedupe?: false when `name` already went through prompt_name/0's own
  # replace-or-rename confirmation - re-checking here would be redundant.
  defp model_add(name, rest, dedupe? \\ true) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [
          company: :string,
          base_url: :string,
          api_key: :string,
          model: :string,
          api: :string,
          max_tokens: :integer,
          temperature: :float,
          default: :boolean
        ]
      )

    with :ok <- validate_scope(name, opts[:company]) do
      {store_name, handle} = resolve_handle(name, opts[:company], dedupe?)
      warn_if_renamed(name, store_name, handle, opts[:company])

      # Guided flow: no --base-url ⇒ use a matching known provider name, or let
      # the user pick one from the catalog. --base-url ⇒ use it directly.
      {base_url, api_key, oauth} = resolve_connection(name, opts)
      save_model(base_url, api_key, oauth, handle, store_name, opts)
    end
  end

  defp resolve_handle(name, company, true), do: unique_handle(name, company)
  defp resolve_handle(name, company, false), do: {name, Company.handle(company, name)}

  defp warn_if_renamed(name, store_name, _handle, _company) when store_name == name, do: :ok

  defp warn_if_renamed(name, _store_name, handle, company) do
    info(dim("a connection named \"#{Company.handle(company, name)}\" already exists - saving this one as \"#{handle}\" instead."))
  end

  defp resolve_connection(name, opts) do
    cond do
      opts[:base_url] ->
        {opts[:base_url], opts[:api_key], nil}

      provider = Pepe.Providers.get(name) ->
        choose_auth(provider, opts)

      true ->
        choose_provider()
    end
  end

  defp save_model(nil, _api_key, _oauth, _handle, _store_name, _opts) do
    error("no provider selected; aborting.")
  end

  defp save_model(base_url, api_key, oauth, handle, store_name, opts) do
    case opts[:model] || pick_model(base_url, api_key) do
      nil ->
        error("no model selected; aborting.")

      id ->
        model = %Model{
          name: handle,
          base_url: base_url,
          api_key: api_key,
          oauth: oauth,
          model: id,
          api: opts[:api] || api_for(base_url),
          max_tokens: opts[:max_tokens],
          temperature: opts[:temperature]
        }

        Config.put_model(model)
        if opts[:default], do: Config.set_default_model_for(opts[:company], store_name)
        ok("model connection #{green(handle)} saved -> #{model.base_url} (#{green(id)})")
    end
  end

  # Step 1: "Select a provider" - interactive catalog of known providers.
  defp choose_provider do
    provider =
      Pepe.Providers.all()
      |> Pepe.TUI.select(
        label: bold("Select a provider:"),
        render_as: fn p ->
          case Pepe.Providers.auth_methods(p) do
            [_single] -> p.label
            methods -> [p.label, dim("  (#{length(methods)} auth methods)")]
          end
        end
      )

    choose_auth(provider)
  end

  # Step 2: "Auth method for {provider}" - submenu (auto-picks when only one).
  defp choose_auth(provider) do
    case Pepe.Providers.auth_methods(provider) do
      [single] ->
        apply_auth(provider, single)

      methods ->
        method =
          Pepe.TUI.select(methods,
            label: bold("Auth method for #{provider.label}:"),
            render_as: & &1.label
          )

        apply_auth(provider, method)
    end
  end

  defp choose_auth(provider, opts) do
    cond do
      opts[:api_key] ->
        {provider.base_url, opts[:api_key], nil}

      provider[:base_url] == nil ->
        choose_auth(provider)

      true ->
        case Pepe.Providers.auth_methods(provider) do
          [%{type: :none}] ->
            {provider.base_url, nil, nil}

          [%{type: :api_key} = method] ->
            {method[:base_url] || provider.base_url, prompt_secret(method[:env] || provider.env), nil}

          _ ->
            choose_auth(provider)
        end
    end
  end

  # Step 3: resolve `{base_url, api_key, oauth}` for the chosen method. `oauth` is
  # nil except for a completed subscription sign-in (refresh/expiry metadata).
  defp apply_auth(_provider, %{type: :custom}) do
    base_url = Owl.IO.input(label: "Base URL (OpenAI-compatible, e.g. https://host/v1):")
    api_key = Owl.IO.input(label: "API key (or ${ENV_VAR}, blank for none):", optional: true)
    {presence(base_url), presence(api_key), nil}
  end

  defp apply_auth(provider, %{type: :none}) do
    info(dim("local provider - no API key needed"))
    {provider.base_url, nil, nil}
  end

  # Subscription sign-in: run the browser PKCE flow when the method declares one.
  defp apply_auth(provider, %{type: :oauth, oauth_flow: flow} = method) when is_map(flow) do
    base_url = method[:base_url] || provider.base_url

    case Pepe.OAuth.login(flow) do
      {:ok, %{access: access} = creds} when is_binary(access) ->
        ok("signed in - subscription token captured")

        oauth = %{
          "provider" => provider.key,
          "refresh" => creds.refresh,
          "expires_at" => creds.expires_at,
          "token_url" => flow.token_url,
          "client_id" => flow.client_id,
          "token_content_type" => to_string(flow[:token_content_type] || :form)
        }

        {base_url, access, oauth}

      {:error, reason} ->
        error("sign-in failed (#{inspect(reason)}); paste a token instead.")
        {base_url, prompt_secret(method[:env]), nil}
    end
  end

  # OAuth method without a flow spec: paste the token by hand.
  defp apply_auth(provider, %{type: :oauth} = method) do
    base_url = method[:base_url] || provider.base_url
    info(dim("paste the OAuth/subscription access token (stored as a bearer token)"))
    {base_url, prompt_secret(method[:env]), nil}
  end

  defp apply_auth(provider, %{type: :api_key} = method) do
    base_url = method[:base_url] || provider.base_url
    {base_url, prompt_secret(method[:env] || provider.env), nil}
  end

  # Read a secret: prefer the env var (stored as a ${VAR} placeholder so it never
  # lands in the config file); otherwise let the user paste it now.
  defp prompt_secret(nil) do
    case Owl.IO.input(
           label: "Token/API key (or ${ENV_VAR}, blank for none):",
           optional: true,
           secret: true
         ) do
      blank when blank in [nil, ""] -> nil
      v -> v
    end
  end

  defp prompt_secret(env) do
    if System.get_env(env) do
      info(dim("using #{env} from your environment"))
      "${#{env}}"
    else
      info("#{env} is not set in your environment.")

      case Owl.IO.input(
             label: "Paste it now (saved to config), or Enter to use ${#{env}} later:",
             optional: true,
             secret: true
           ) do
        blank when blank in [nil, ""] -> "${#{env}}"
        v -> v
      end
    end
  end

  defp presence(""), do: nil
  defp presence(v), do: v

  # Fetch the provider's model catalog (needs Req running). Carries the resolved
  # `api` so subscription endpoints (Codex/Responses) use the right discovery.
  defp fetch_models(base_url, api_key) do
    {:ok, _} = Application.ensure_all_started(:req)

    probe = %Model{
      name: "_probe",
      base_url: base_url,
      api_key: api_key,
      api: api_for(base_url),
      model: nil
    }

    if api_key && Pepe.Config.interpolate(api_key) in [nil, ""] do
      info(dim("note: api key #{api_key} resolves to empty - export the env var, or this may 401"))
    end

    Pepe.LLM.list_models(probe)
  end

  # Step 3: "Loading available models" -> "Default model" picker. Tries the live
  # catalog first (including the Codex subscription's own /models endpoint); if
  # that returns nothing, falls back to a curated list, then to manual entry.
  defp pick_model(base_url, api_key) do
    info(dim("Loading available models..."))

    case fetch_models(base_url, api_key) do
      {:ok, [_ | _] = ids} ->
        choose_model(ids)

      _ ->
        case curated_models(base_url) do
          [_ | _] = ids ->
            choose_model(ids)

          [] ->
            info(dim("This provider doesn't list models - enter the model id."))
            prompt_model_id()
        end
    end
  end

  # Curated fallback model ids declared on the auth method whose endpoint matches.
  defp curated_models(base_url) do
    auth_methods()
    |> Enum.find_value([], fn method ->
      if method[:base_url] == base_url, do: method[:models]
    end)
  end

  # The API protocol for an endpoint (e.g. "openai-responses" for Codex), defaults
  # to OpenAI Chat Completions.
  defp api_for(base_url) do
    auth_methods()
    |> Enum.find_value("openai-completions", fn method ->
      if method[:base_url] == base_url, do: method[:api]
    end)
  end

  defp auth_methods, do: Enum.flat_map(Pepe.Providers.all(), &(&1[:auth] || []))

  defp choose_model(ids) do
    # Long catalogs (OpenRouter has 300+) get an optional substring filter before
    # the picker so the numbered list stays navigable.
    ids = if Enum.count_until(ids, 21) > 20, do: filter_ids(ids), else: ids
    Pepe.TUI.select(ids, label: bold("Select the default model:"))
  end

  defp filter_ids(ids) do
    case Owl.IO.input(label: "Filter models (substring, blank for all):", optional: true) do
      blank when blank in [nil, ""] -> ids
      filter -> apply_filter(ids, filter)
    end
  end

  defp apply_filter(ids, filter) do
    down = String.downcase(filter)

    case Enum.filter(ids, &String.contains?(String.downcase(&1), down)) do
      [] -> ids
      filtered -> filtered
    end
  end

  defp prompt_model_id do
    case Owl.IO.input(label: "Type the model id:", optional: true) do
      blank when blank in [nil, ""] -> nil
      id -> id
    end
  end

  defp describe({:http_error, status, _body}), do: "HTTP #{status}"
  defp describe(reason), do: inspect(reason)

  ###
  ### agent
  ###

  ###
  ### usage / billing
  ###

  @granularity_atoms %{
    "hour" => :hour,
    "day" => :day,
    "week" => :week,
    "month" => :month,
    "year" => :year
  }

  defp usage_cmd(["prices" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [refresh: :boolean])

    if opts[:refresh] do
      info("fetching current prices from OpenRouter + LiteLLM...")

      case Pepe.Pricing.refresh() do
        {:ok, n} -> ok("cached #{n} model prices")
        {:error, reason} -> error("couldn't refresh prices: #{inspect(reason)}")
      end
    end

    case Pepe.Pricing.cache_info() do
      nil ->
        info(
          "no live price cache yet - using built-in seed prices.\n" <>
            "  refresh: mix pepe usage prices --refresh"
        )

      %{fetched_at: at, count: c} ->
        info("#{c} live prices cached · refreshed #{local_datetime(at)}")
    end
  end

  defp usage_cmd(["export" | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [company: :string, month: :string, format: :string, output: :string]
      )

    cond do
      is_nil(opts[:company]) ->
        error("--company is required, e.g. mix pepe usage export --company acme")

      not Config.company_exists?(opts[:company]) ->
        error("unknown company: #{opts[:company]}")

      true ->
        inv = Pepe.Usage.invoice(opts[:company], month: opts[:month])

        {body, ext} =
          if opts[:format] == "csv",
            do: {Pepe.Usage.Invoice.to_csv(inv), "csv"},
            else: {Pepe.Usage.Invoice.to_markdown(inv), "md"}

        case opts[:output] do
          nil ->
            puts(body)

          path ->
            File.write!(path, body)
            ok("wrote #{ext} invoice for #{opts[:company]} #{inv.period.label} -> #{path}")
        end
    end
  end

  defp usage_cmd(["help"]), do: usage_help()

  defp usage_cmd(rest) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [company: :string, granularity: :string, limit: :integer]
      )

    case @granularity_atoms[opts[:granularity] || "month"] do
      nil ->
        error("unknown cycle: #{opts[:granularity]} (use hour|day|week|month|year)")

      gran ->
        scope = opts[:company] || :all
        s = Pepe.Usage.summary(scope, gran, limit: opts[:limit] || 24)
        print_usage(s, scope)
    end
  end

  defp print_usage(s, scope) do
    label = if scope == :all, do: "all scopes", else: scope
    puts("#{bold("usage")} · #{label} · by #{s.granularity} · #{s.currency}\n")

    if s.buckets == [] do
      info("no usage recorded yet for this scope.")
    else
      Enum.each(s.buckets, fn b ->
        puts(
          "  #{String.pad_trailing(b.key, 18)} " <>
            "#{String.pad_leading(fmt_tok(b.total), 10)} tok  " <>
            "cost #{String.pad_leading(fmt_money(b.cost, s.currency), 12)}  " <>
            "bill #{String.pad_leading(fmt_money(b.billable, s.currency), 12)}"
        )
      end)

      t = s.totals

      puts(
        "\n  #{bold(String.pad_trailing("TOTAL", 18))} " <>
          "#{String.pad_leading(fmt_tok(t.total), 10)} tok  " <>
          "cost #{String.pad_leading(fmt_money(t.cost, s.currency), 12)}  " <>
          "bill #{String.pad_leading(fmt_money(t.billable, s.currency), 12)}"
      )
    end

    if scope == :all and s.by_company != [] do
      puts("\n#{bold("by company")}")
      Enum.each(s.by_company, &print_company_line(&1, s.currency))
    end
  end

  defp print_company_line(c, currency) do
    markup = if c.markup != 1.0, do: " (×#{c.markup})", else: ""

    puts(
      "  #{String.pad_trailing(c.key, 16)} " <>
        "cost #{String.pad_leading(fmt_money(c.cost, currency), 12)}  " <>
        "bill #{String.pad_leading(fmt_money(c.billable, currency), 12)}#{markup}"
    )
  end

  defp fmt_tok(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_tok(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_tok(n), do: Integer.to_string(n)

  defp fmt_money(amount, currency),
    do: "#{currency} #{:erlang.float_to_binary(amount / 1, decimals: 2)}"

  # `traces` - list recent agent runs, or replay one by id.
  defp traces_cmd(["help"]), do: traces_help()

  defp traces_cmd(rest) do
    {opts, args} = OptionParser.parse!(rest, strict: [company: :string, limit: :integer])
    scope = opts[:company] || :all

    case args do
      [id] -> print_trace(find_trace(scope, id))
      [] -> print_trace_list(scope, opts[:limit] || 30)
      _ -> error("usage: mix pepe traces [--company NAME] [--limit N] [ID]")
    end
  end

  defp print_trace_list(scope, limit) do
    scopes = if scope == :all, do: Pepe.Trace.scopes(), else: [to_string(scope)]

    traces =
      scopes
      |> Enum.flat_map(fn s -> Enum.map(Pepe.Trace.recent(s, limit), &Map.put(&1, "scope", s)) end)
      |> Enum.sort_by(& &1["at"], :desc)
      |> Enum.take(limit)

    label = if scope == :all, do: "all scopes", else: scope
    puts("#{bold("traces")} · #{label}\n")

    if traces == [] do
      info("no runs recorded yet.")
    else
      Enum.each(traces, &print_trace_line/1)

      puts("\n#{dim("replay one: mix pepe traces ID")}")
    end
  end

  defp print_trace_line(t) do
    kind = get_in(t, ["outcome", "kind"]) || "?"
    mark = if kind == "error", do: red("✗"), else: green("✓")

    puts(
      "  #{mark} #{dim(t["id"])}  #{String.pad_trailing(t["agent"], 20)} " <>
        "#{String.pad_leading("#{t["ms"]}ms", 8)}  #{dim(Enum.join(t["tools"] || [], ","))}"
    )
  end

  defp find_trace(:all, id) do
    Enum.find_value(Pepe.Trace.scopes(), fn s -> Pepe.Trace.get(s, id) end)
  end

  defp find_trace(scope, id), do: Pepe.Trace.get(to_string(scope), id)

  defp print_trace(nil), do: error("no trace with that id.")

  defp print_trace(t) do
    puts("#{bold(t["agent"])}  #{dim("#{t["ms"]}ms")}  #{trace_outcome(t["outcome"])}")
    if t["session"], do: puts(dim("session: #{t["session"]}"))
    if t["prompt"], do: puts("\n#{bold("prompt")}\n  #{t["prompt"]}")
    puts("")

    Enum.each(t["events"] || [], &print_trace_event/1)
  end

  defp print_trace_event(%{"t" => "tool_call"} = ev),
    do: puts("  #{yellow("→")} #{bold(ev["name"])} #{dim(ev["args"] || "")}")

  defp print_trace_event(%{"t" => "tool_result"} = ev), do: puts("    #{dim(clip_line(ev["out"]))}")

  defp print_trace_event(%{"t" => "tool_denied"} = ev),
    do: puts("  #{red("⨯")} #{ev["name"]} #{dim("blocked")}")

  defp print_trace_event(%{"t" => "assistant"} = ev), do: puts("  #{green("•")} #{ev["text"]}")

  defp print_trace_event(%{"t" => "failover"} = ev),
    do: puts("  #{dim("failover #{ev["from"]} → #{ev["to"]}")}")

  defp print_trace_event(%{"t" => "usage"} = ev),
    do: puts("  #{dim("#{ev["model"]}: in #{ev["in"]} / out #{ev["out"]} tok")}")

  defp print_trace_event(%{"t" => "error"} = ev), do: puts("  #{red("!")} #{ev["reason"]}")
  defp print_trace_event(_ev), do: :ok

  defp trace_outcome(%{"kind" => "error", "reason" => r}), do: red("error: #{r}")
  defp trace_outcome(%{"kind" => "ok"}), do: green("ok")
  defp trace_outcome(_), do: dim("?")

  defp clip_line(nil), do: ""

  defp clip_line(s) do
    s = s |> to_string() |> String.replace("\n", " ")
    if String.length(s) > 120, do: String.slice(s, 0, 120) <> " ...", else: s
  end

  defp traces_help do
    puts("""
    #{bold("mix pepe traces")} - inspect and replay recent agent runs

      traces [--company NAME] [--limit N]   list recent runs (any surface)
      traces ID                             replay one run step by step

    Every run is recorded under <PEPE_HOME>/data/traces; the dashboard has the same
    view under Traces.
    """)
  end

  # `plugin` - install/list/remove user plugins (`.exs` under <PEPE_HOME>/plugins).
  defp plugin_cmd(["help"]), do: plugin_help()
  defp plugin_cmd([]), do: plugin_list()
  defp plugin_cmd(["list"]), do: plugin_list()

  defp plugin_cmd(["install" | rest]) do
    {opts, args, _} = OptionParser.parse(rest, strict: [force: :boolean])

    case args do
      [src] -> plugin_install(src, force: opts[:force] == true)
      _ -> error("usage: mix pepe plugin install SRC [--force]")
    end
  end

  defp plugin_cmd(["scan", src]) do
    case Pepe.Plugins.scan(src) do
      %{} = scan -> info(Pepe.Skills.Sentinel.report(scan))
      {:error, reason} -> error("scan failed: #{inspect(reason)}")
    end
  end

  defp plugin_cmd(["remove", name]) do
    case Pepe.Plugins.remove(name) do
      {:ok, _} -> ok("removed #{name}")
      {:error, :not_found} -> error("no plugin named #{name}")
    end
  end

  defp plugin_cmd(_), do: error("usage: mix pepe plugin list|install SRC [--force]|scan SRC|remove NAME")

  defp plugin_install(src, force: force?) do
    case Pepe.Plugins.install(src, force: force?) do
      {:ok, name, scan} ->
        ok("installed #{green(name)} into #{Pepe.Plugins.dir()}")
        if scan.verdict != :safe, do: info(Pepe.Skills.Sentinel.report(scan))
        info(dim("A plugin runs with full access to the app; review what it does before trusting it."))

      {:error, {:unsafe, scan}} ->
        error("refused: the Sentinel flagged this plugin as dangerous.")
        info(Pepe.Skills.Sentinel.report(scan))
        info(dim("If you have reviewed it and trust the source, re-run with --force."))

      {:error, reason} ->
        error("install failed: #{inspect(reason)}")
    end
  end

  defp plugin_list do
    case Pepe.Plugins.packages() do
      [] ->
        info("No plugins installed. Add one: mix pepe plugin install <path|url|tar.gz>")

      pkgs ->
        info(bold("installed plugins") <> dim("  (#{Pepe.Plugins.dir()})"))

        Enum.each(pkgs, &print_plugin_line/1)

        providers = Pepe.Webhooks.providers() -- ["whatsapp"]
        if providers != [], do: info(dim("\nchannel providers from plugins: #{Enum.join(providers, ", ")}"))
    end
  end

  defp print_plugin_line(p) do
    desc = get_in(p.manifest || %{}, ["description"])
    info("  #{green(p.name)} #{dim("(#{p.kind})")}#{if desc, do: dim(" - " <> desc), else: ""}")
  end

  # `migrate` - import an existing setup from another agent runtime.
  defp migrate_cmd(["help"]), do: migrate_help()

  defp migrate_cmd(rest) do
    {opts, args, _} = OptionParser.parse(rest, strict: [from: :string, dry_run: :boolean])

    case args do
      [source] -> run_migrate(source, opts)
      _ -> error("usage: mix pepe migrate #{Enum.join(Pepe.Migrate.sources(), "|")} [--from PATH] [--dry-run]")
    end
  end

  defp run_migrate(source, opts) do
    case Pepe.Migrate.run(source, from: opts[:from], dry_run: opts[:dry_run] == true) do
      {:ok, report} ->
        print_migrate_report(report)

      {:error, {:unknown_source, s}} ->
        error("unknown source #{inspect(s)}; try: #{Enum.join(Pepe.Migrate.sources(), ", ")}")

      {:error, {:home_not_found, home}} ->
        error("nothing to import: #{home} not found (point at it with --from)")
    end
  end

  defp print_migrate_report(report) do
    tag = if report.dry_run, do: dim(" [dry-run, nothing written]"), else: ""
    info("#{bold("migrate " <> report.source)} #{dim(report.home)}#{tag}\n")

    Enum.each(report.applied, fn a -> info("  #{green("✓")} #{a.kind} #{bold(a.name)}") end)
    Enum.each(report.skipped, fn s -> info("  #{dim("·")} #{dim("skipped #{s.what}: #{s.reason}")}") end)

    info("\n#{bold("#{length(report.applied)} imported")}, #{length(report.skipped)} skipped.")
    if report.dry_run, do: info(dim("Re-run without --dry-run to apply."))
    unless report.dry_run, do: info(dim("Review secrets (${ENV_VAR} refs) and each agent's tools before running."))
  end

  defp migrate_help do
    puts("""
    #{bold("mix pepe migrate")} - import an existing setup from another agent runtime

      migrate #{Enum.join(Pepe.Migrate.sources(), "|")} [--from PATH] [--dry-run]

    Reads the source's on-disk config and maps its models and agents into Pepe (personas,
    memory and a Telegram token come along; tools default and other channels are reported
    for you to set up). `--from` points at the source home; `--dry-run` shows the plan
    without writing anything.
    """)
  end

  defp plugin_help do
    puts("""
    #{bold("mix pepe plugin")} - install and manage user plugins

      plugin list                 list installed plugins and what they add
      plugin install SRC [--force]  install from a .exs, a directory, a .tar.gz, or an
                                  http(s) URL (incl. a GitHub repo). The code is scanned
                                  first; a dangerous verdict is refused unless --force.
      plugin scan SRC             security-scan a plugin without installing it
      plugin remove NAME          delete an installed plugin

    Plugins are Elixir loaded at runtime (no rebuild). One can add tools or channels (a
    webhook provider). A plugin runs with full access to the app, so only install from a
    source you trust. Example: the Chatwoot channel in examples/plugins.

    An agent holding the manage_plugin tool can scan/install/list/remove the same way
    from a chat - with no --force escape hatch; a dangerous verdict always stays here.
    """)
  end

  defp usage_help do
    puts("""
    #{bold("mix pepe usage")} - token metering & billing

      usage [--company NAME] [--granularity CYCLE] [--limit N]
                                    report token usage & cost by cycle
                                    CYCLE = hour|day|week|month|year (default month)
                                    no --company = all scopes, broken down per company
      usage prices [--refresh]      show (or refresh) the live price cache
      usage export --company NAME [--month YYYY-MM] [--format markdown|csv] [--output FILE]
                                    generate a client invoice (an agent can do this
                                    too, via the export_invoice tool, then email it)

    Cost = tokens × the model's price (set per model, or auto from the price book).
    The amount to bill = cost × the company's markup (set per company; blank = 1.0).
    Every model call is metered automatically and attributed to the agent's company.
    """)
  end

  ###
  ### hooks commands
  ###

  defp hooks_cmd(["list" | _]) do
    info("available hooks: #{Enum.join(Pepe.Hooks.names(), ", ")}")
    info(dim("enable per agent: mix pepe agent add NAME --hooks pii_redact,llm_redact"))
    info(dim("settings live under \"hooks\" in ~/.pepe/config.json"))
  end

  defp hooks_cmd(["generate", desc | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [model: :string, save: :boolean])
    model = opts[:model] || Config.default_model_name()

    if is_nil(model) do
      error("no model to generate with - pass --model NAME (or set a default model)")
    else
      generate_hook(desc, model, opts)
    end
  end

  defp hooks_cmd(_) do
    info("""
    mix pepe hooks - message-flow redaction hooks

      list                          show available hooks
      generate "what to redact" [--model NAME] [--save]
                                    let a model build a pii_redact config (packs +
                                    custom regex), validated before it's saved
    """)
  end

  defp generate_hook(desc, model, opts) do
    info("asking #{model} to build a pii_redact config...")

    case Pepe.Hooks.Generator.generate(desc, model) do
      {:ok, config, dropped} ->
        puts(Jason.encode!(config, pretty: true))
        if dropped != [], do: info(dim("dropped (invalid): #{Enum.join(dropped, ", ")}"))
        save_or_hint_hook(config, opts[:save])

      {:error, reason} ->
        error("couldn't generate: #{inspect(reason)}")
    end
  end

  defp save_or_hint_hook(config, true) do
    Config.put_hook_settings("pii_redact", config)
    ok("saved to hooks.pii_redact")
  end

  defp save_or_hint_hook(_config, _save?) do
    info(dim("re-run with --save to store it, or paste it under \"hooks\" yourself"))
  end

  ###
  ### eval
  ###

  defp eval_cmd([]) do
    case Pepe.Eval.suites() do
      [] ->
        info("No eval suites yet. Add JSON files under #{Pepe.Eval.dir()}, for example:")

        info(dim(~s(  [{"name":"greets","agent":"assistant","prompt":"say hi","expect":{"contains":["hi"]}}])))

      suites ->
        eval_report(Enum.flat_map(suites, &run_and_print_suite/1))
    end
  end

  defp eval_cmd(["list"]) do
    case Pepe.Eval.suites() do
      [] -> info("No eval suites found.")
      suites -> Enum.each(suites, fn s -> info("  #{s}  #{dim("(#{length(Pepe.Eval.load(s))} cases)")}") end)
    end
  end

  defp eval_cmd(["--seed"]) do
    case Pepe.Eval.seed() do
      [] -> info("Nothing to seed: every bundled suite is already in #{Pepe.Eval.dir()}.")
      names -> ok("Seeded #{length(names)} suite(s) into #{Pepe.Eval.dir()}: #{Enum.join(names, ", ")}")
    end
  end

  # Promote a conversation that already happened into a case that has to keep happening.
  defp eval_cmd(["add" | rest]) do
    {opts, args, _} =
      OptionParser.parse(rest,
        strict: [suite: :string, name: :string, contains: :string, scope: :string]
      )

    case args do
      [id] -> eval_add(id, opts)
      _ -> error("usage: mix pepe eval add TRACE_ID [--suite NAME] [--name NAME] [--contains \"a,b\"] [--scope COMPANY]")
    end
  end

  defp eval_cmd(["help"]), do: eval_help()
  defp eval_cmd([suite]), do: eval_report(run_and_print_suite(suite))
  defp eval_cmd(_), do: error("usage: mix pepe eval [SUITE | list | --seed]")

  defp eval_add(id, opts) do
    suite = opts[:suite] || "recorded"
    contains = opts[:contains] |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case Pepe.Eval.FromTrace.promote(opts[:scope], id, suite, name: opts[:name], contains: contains) do
      {:ok, kase} -> print_added_case(kase, suite, contains)
      {:error, why} -> error(why)
    end
  end

  defp print_added_case(kase, suite, contains) do
    tools = kase["expect"]["tool_called"] || []

    ok("added to #{green(suite)}: #{kase["name"]}")
    info(dim("  agent: #{kase["agent"]}"))
    info(dim("  asserts it still calls: #{(tools == [] && "(no tools ran)") || Enum.join(tools, ", ")}"))
    unless contains == [], do: info(dim("  and that the reply still says: #{Enum.join(contains, ", ")}"))
    info(dim("  run it with: mix pepe eval #{suite}"))
  end

  defp eval_help do
    puts("""
    #{bold("mix pepe eval")} - replay prompts through an agent and assert on the result

      eval                 run every suite (bundled + your own)
      eval SUITE           run one suite by name
      eval list            list available suites and their case counts
      eval --seed          copy the bundled suites into #{Pepe.Eval.dir()} to edit
      eval add TRACE_ID    turn a conversation that already happened into a case

    Suites are JSON under #{Pepe.Eval.dir()} (yours) or shipped with Pepe; a case asserts
    the reply (contains / not_contains / matches) and the tools it used (tool_called /
    tool_not_called). Omit a case's "agent" to run it against your default agent.

    #{bold("eval add")} is the one to reach for. Your traces are the test data you already
    have: when an agent handles something well, promote that run and it becomes a case. It
    keeps the prompt, the agent, and the tools the agent used - the tools being the assertion
    worth having, since they are what changes when a persona edit goes wrong (the agent stops
    looking things up and starts inventing them). It does not demand the same sentence back,
    because two runs never produce one, and a test that insists on it gets muted and then
    protects nothing. Name the words that were the point and they get asserted too:

      mix pepe eval add a1b2c3 --suite support --contains "refund,5 business days"

    Options: --suite (default "recorded"), --name, --contains "a,b", --scope COMPANY.
    """)
  end

  defp run_and_print_suite(suite) do
    results = Pepe.Eval.run_suite(suite)
    info(bold("▸ #{suite}"))

    Enum.each(results, fn r ->
      if r.passed do
        info("  " <> green("✓") <> " #{r.name}")
      else
        info("  " <> red("✗") <> " #{r.name}")
        Enum.each(r.failures, &info(dim("      #{&1}")))
      end
    end)

    info(dim("  #{Enum.count(results, & &1.passed)}/#{length(results)} passed"))
    results
  end

  defp eval_report(results) do
    passed = Enum.count(results, & &1.passed)
    info("")
    info(bold("total: #{passed}/#{length(results)} passed"))
    if passed != length(results), do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

  ###
  ### company commands
  ###

  defp company_cmd(["add", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [description: :string])
    meta = if opts[:description], do: %{"description" => opts[:description]}, else: %{}

    case Config.add_company(name, meta) do
      :ok ->
        ok(
          "company #{green(name)} created - add agents with " <>
            "#{bold("mix pepe agent add NAME --company #{name}")}"
        )

      {:error, :invalid_name} ->
        error("invalid company name #{inspect(name)} - use letters, digits, - and _ only")

      {:error, :already_exists} ->
        error("company #{name} already exists")
    end
  end

  defp company_cmd(["set", name | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [budget: :string, message_limit: :string, markup: :string, description: :string]
      )

    if opts == [] do
      error(
        "usage: mix pepe company set NAME [--budget N|none] [--message-limit N|none] " <>
          "[--markup N|none] [--description \"...\"|none]"
      )
    else
      meta =
        %{}
        |> put_company_opt(opts, :budget, "budget", &parse_money_opt/1)
        |> put_company_opt(opts, :message_limit, "message_limit", &parse_count_opt/1)
        |> put_company_opt(opts, :markup, "markup", &parse_money_opt/1)
        |> put_company_opt(opts, :description, "description", &parse_description_opt/1)

      case Config.update_scope(scope_arg(name), meta) do
        :ok -> ok("updated #{green(name)}")
        {:error, :not_found} -> error("unknown company: #{name}")
      end
    end
  end

  defp company_cmd(["set" | _]),
    do:
      error(
        "usage: mix pepe company set NAME|root [--budget N|none] [--message-limit N|none] " <>
          "[--markup N|none] [--description \"...\"|none]"
      )

  defp company_cmd(["reset-messages", name | _]) do
    if name == "root" or Config.company_exists?(name) do
      scope = scope_arg(name)
      before = Pepe.Usage.message_count_month_to_date(scope)
      Pepe.Usage.reset_messages(scope)
      ok("reset #{green(name)}'s message count (was #{before}) for the rest of this month")
    else
      error("unknown company: #{name}")
    end
  end

  defp company_cmd(["reset-messages" | _]),
    do: error("usage: mix pepe company reset-messages NAME|root")

  defp company_cmd(["reset-budget", name | _]) do
    if name == "root" or Config.company_exists?(name) do
      scope = scope_arg(name)
      before = :erlang.float_to_binary(Pepe.Usage.month_to_date(scope) / 1, decimals: 2)
      Pepe.Usage.reset_budget(scope)
      ok("reset #{green(name)}'s spend count (was #{Config.currency()} #{before}) for the rest of this month")
    else
      error("unknown company: #{name}")
    end
  end

  defp company_cmd(["reset-budget" | _]),
    do: error("usage: mix pepe company reset-budget NAME|root")

  defp company_cmd(["list" | _]) do
    case Config.companies() do
      [] ->
        info("no companies. everything runs in the root scope. add one:\n  mix pepe company add acme")

      companies ->
        Enum.each(companies, &print_company_summary/1)
    end
  end

  defp company_cmd(["remove", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [force: :boolean])

    case Config.delete_company(name, force: opts[:force] || false) do
      :ok ->
        ok("removed company #{name}")

      {:error, :not_found} ->
        error("unknown company: #{name}")

      {:error, {:not_empty, n}} ->
        error(
          "company #{name} still has #{n} agent#{if n == 1, do: "", else: "s"} - " <>
            "move them out first, or pass --force to drop them too"
        )
    end
  end

  defp company_cmd(["rename", old, new | _]) do
    case Config.rename_company(old, new) do
      :ok ->
        ok(
          "renamed company #{green(old)} -> #{green(new)} - agents, models, routes, " <>
            "crons, watches, bots, tokens and files all re-keyed"
        )

      {:error, :not_found} ->
        error("unknown company: #{old}")

      {:error, :already_exists} ->
        error("company #{new} already exists")

      {:error, :invalid_name} ->
        error("invalid name #{inspect(new)} - use letters, digits, - and _ only")
    end
  end

  defp company_cmd(["rename" | _]),
    do: error("usage: mix pepe company rename OLD NEW")

  defp company_cmd(cmd) when cmd in [[], ["help"]] do
    puts("""
    #{bold("mix pepe company")} - multi-tenant scopes

      add NAME [--description "..."]   create a company (an isolated tenant)
      set NAME|root [--budget N|none] [--message-limit N|none] [--markup N|none] [--description "..."|none]
                                       update caps/markup/description (only the flags given change)
      reset-messages NAME|root        zero the message count early, before the month rolls over
      reset-budget NAME|root          zero the spend count early, before the month rolls over
      list                            list companies + how many agents each has
      rename OLD NEW                  rename a company (re-keys all its agents & bindings)
      remove NAME [--force]           delete a company (--force also drops its agents)

    --budget is a monthly spend cap (in the billing currency); --message-limit is a
    monthly cap on customer-originated messages. Either blocks that scope's agents
    once reached, until next month - independent caps, set either, both, or neither.
    "root" is the single-tenant default (every command without --company) - it isn't
    a real company (it never shows in `list`, can't be renamed/removed) but it can
    have its own budget/message-limit/markup just like a company can, via
    `company set root ...`. An agent can be exempted from --message-limit
    individually: pass --exempt-message-limit when creating it with `agent add`, or
    toggle it later on the dashboard's agent edit page (there's no CLI way to flip
    it on an existing agent without touching its other settings - `agent add` on an
    existing name replaces the whole agent, it doesn't patch one field).

    Without --company, every command uses the root scope. Add --company NAME to an
    agent/model command to act inside that company; its agents, workspaces,
    shared/ space and models are isolated from other companies.
    """)
  end

  defp company_cmd(other),
    do: error("unknown company command: #{Enum.join(other, " ")} (try: mix pepe company help)")

  defp print_company_summary(name) do
    count = length(Config.agents_in(name))
    desc = (Config.get_company(name) || %{})["description"]
    suffix = if desc, do: " - #{desc}", else: ""
    puts("#{bold(name)} (#{count} agent#{if count == 1, do: "", else: "s"})#{suffix}")
  end

  # The CLI's "root" sentinel -> the nil scope every Config/Usage function expects.
  defp scope_arg("root"), do: nil
  defp scope_arg(name), do: name

  defp put_company_opt(meta, opts, key, field, parse) do
    case Keyword.fetch(opts, key) do
      :error -> meta
      {:ok, raw} -> Map.put(meta, field, parse.(raw))
    end
  end

  # "none" (or blank) clears the field; only a positive number is worth storing.
  defp parse_money_opt(raw) do
    case raw |> to_string() |> String.trim() |> String.downcase() do
      v when v in ["", "none"] ->
        nil

      v ->
        case Float.parse(String.replace(v, ",", ".")) do
          {f, _} when f > 0 -> f
          _ -> nil
        end
    end
  end

  defp parse_count_opt(raw) do
    case raw |> to_string() |> String.trim() |> String.downcase() do
      v when v in ["", "none"] ->
        nil

      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end

  defp parse_description_opt(raw) do
    case raw |> to_string() |> String.trim() do
      v when v in ["", "none"] -> nil
      v -> v
    end
  end

  ###
  ### API token commands
  ###

  @token_appearance_switches [title: :string, logo: :string, color: :string, theme: :string, greeting: :string, position: :string]

  defp token_cmd(["add" | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict:
          [company: :string, agent: :string, label: :string, widget: :boolean, allowed_origin: :string] ++
            @token_appearance_switches
      )

    attrs =
      [
        company: opts[:company],
        agent: opts[:agent],
        label: opts[:label],
        widget: opts[:widget] == true,
        allowed_origin: opts[:allowed_origin]
      ] ++ Keyword.take(opts, Keyword.keys(@token_appearance_switches))

    case Config.add_api_token(attrs) do
      {:ok, raw, id} -> print_new_token(raw, id, opts)
      {:error, reason} -> print_token_add_error(reason, opts)
    end
  end

  defp token_cmd(["list" | _]) do
    case Config.api_tokens() do
      [] ->
        info("no API tokens - the /v1 API is open. lock it with: mix pepe token add")

      tokens ->
        Enum.each(tokens, &print_token_line/1)
    end
  end

  defp token_cmd(["revoke", id | _]) do
    case Config.revoke_api_token(id) do
      :ok -> ok("revoked token #{id}")
      {:error, :not_found} -> error("unknown token id: #{id}")
    end
  end

  defp token_cmd(["update", id | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: @token_appearance_switches)

    case Config.update_widget_token(id, Keyword.take(opts, Keyword.keys(@token_appearance_switches))) do
      :ok -> ok("widget token #{id} updated")
      {:error, :not_found} -> error("unknown token id: #{id}")
      {:error, :not_widget} -> error("token #{id} isn't a widget token - only a widget's appearance can be updated")
    end
  end

  defp token_cmd(_) do
    puts("""
    #{bold("mix pepe token")} - API access tokens for /v1

      add [--company CO] [--agent HANDLE] [--label "..."]   mint a token (shown once
                                                              for a regular token;
                                                              retrievable via `list`
                                                              for --widget)
      list                                                  list tokens (scope + fingerprint,
                                                              or a widget token's full value)
      revoke ID                                             revoke a token
      update ID [--title ...] [--logo ...] [--color ...]    edit a WIDGET token's
             [--theme dark|light] [--greeting ...]           appearance in place -
             [--position left|right]                         never its secret/scope

    No tokens ⇒ the /v1 API is open. The first token locks it: every call then needs
    `Authorization: Bearer pepe_...`. A token scoped to a company reaches only its
    agents; scoped to an agent, only that one.

    --widget mints a public, embeddable-chat-widget token (see `mix pepe token add
    --agent HANDLE --widget --allowed-origin https://example.com`); add appearance
    with --title/--logo/--color/--theme/--greeting/--position on either `add` or
    `update` - a widget token's raw value stays retrievable since it sits in public
    page source already, unlike a regular token's.
    """)
  end

  defp print_new_token(raw, id, opts) do
    scope = token_scope_label(opts)
    kind = if opts[:widget], do: " (widget)", else: ""
    ok("API token created (id #{green(id)}, scope: #{scope}#{kind})")
    puts("\n  #{bold(raw)}\n")

    if opts[:widget] do
      info("A widget token isn't a secret worth hiding - see it again any time with `mix pepe token list`.")
    else
      info("Save it now - it is shown only once and stored only as a hash.")
    end
  end

  defp token_scope_label(opts) do
    cond do
      opts[:agent] -> "agent #{opts[:agent]}"
      opts[:company] -> "company #{opts[:company]}"
      true -> "root"
    end
  end

  defp print_token_add_error(:widget_needs_agent, _opts),
    do: error("a --widget token must be --agent-locked (a public embed always pins to one agent)")

  defp print_token_add_error(:unknown_company, opts), do: error("unknown company: #{opts[:company]}")
  defp print_token_add_error(:unknown_agent, opts), do: error("unknown agent: #{opts[:agent]}")

  defp print_token_add_error(:agent_out_of_scope, opts),
    do: error("agent #{opts[:agent]} is not in company #{opts[:company] || "(root)"}")

  defp print_token_line(t) do
    scope = t["agent"] || t["company"] || "root"
    label = if t["label"], do: " - #{t["label"]}", else: ""
    kind = if t["kind"] == "widget", do: " (widget, #{t["allowed_origin"] || "no origin set"})", else: ""
    # A widget token's raw value is retrievable (public page source anyway);
    # a regular token only ever shows its safe fingerprint prefix.
    shown = if t["kind"] == "widget", do: t["token"], else: t["prefix"]
    puts("#{bold(t["id"])}  #{shown}  [#{scope}]#{kind}#{label}")
  end

  ###
  ### watch commands (one-shot "notify me when X")
  ###

  defp watch_cmd(["add", description | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [
          probe: :string,
          contains: :string,
          message: :string,
          every: :integer,
          deliver: :string
        ]
      )

    case opts[:probe] do
      nil ->
        error("watch add needs --probe \"<command>\" (agent-checked watches are created from chat)")

      cmd ->
        success = if opts[:contains], do: %{"contains" => opts[:contains]}, else: "exit_zero"

        watch = %Pepe.Config.Watch{
          id: watch_id(description),
          description: description,
          agent: Config.default_agent_name(),
          trigger: %{"type" => "probe", "command" => cmd, "success" => success},
          on_fire: %{"type" => "template", "text" => opts[:message] || "✅ #{description}"},
          origin: watch_origin(opts[:deliver]),
          interval_s: max(opts[:every] || 120, 30),
          state: "pending",
          created: 0
        }

        Config.put_watch(watch)

        ok("watch #{green(watch.id)} created (probe every #{watch.interval_s}s -> #{watch.origin["channel"]})")
    end
  end

  defp watch_cmd(["list" | _]) do
    case Config.watches() do
      [] ->
        info("no watches. create one from chat, or: mix pepe watch add \"site up\" --probe \"curl -sf https://x\"")

      watches ->
        Enum.each(watches, fn w ->
          detail = w.trigger["command"] || w.trigger["prompt"] || ""

          puts(
            "#{bold(w.id)} [#{w.state}] - #{w.description}\n  #{w.trigger["type"]} every #{w.interval_s}s · checks #{w.checks}/#{w.max_checks} · #{String.slice(to_string(detail), 0, 60)}"
          )
        end)
    end
  end

  defp watch_cmd(["pause", id | _]), do: watch_set_state(id, "paused", "paused")

  defp watch_cmd(["resume", id | _]) do
    case Config.get_watch(id) do
      nil ->
        error("unknown watch: #{id}")

      w ->
        Config.put_watch(%{w | state: "pending", next_check: nil})
        ok("watch #{id} resumed")
    end
  end

  defp watch_cmd(["cancel", id | _]) do
    case Config.get_watch(id) do
      nil ->
        error("unknown watch: #{id}")

      _ ->
        Config.delete_watch(id)
        ok("watch #{id} cancelled")
    end
  end

  defp watch_cmd(_) do
    puts("""
    #{bold("mix pepe watch")} - one-shot "notify me when X" watches

      add DESC --probe "<cmd>" [--contains STR] [--message "..."] [--every SECS] [--deliver telegram:<chat>|log]
      list                          show all watches
      pause ID / resume ID          pause or resume a watch
      cancel ID                     delete a watch

    A watch polls a cheap probe and notifies ONCE when it passes, then stops. It's
    durable (survives restarts). Agent-judged watches are created from chat via the
    `watch` tool; the CLI creates probe watches.
    """)
  end

  defp watch_set_state(id, state, label) do
    case Config.get_watch(id) do
      nil ->
        error("unknown watch: #{id}")

      w ->
        Config.put_watch(%{w | state: state})
        ok("watch #{id} #{label}")
    end
  end

  defp watch_origin("telegram:" <> chat),
    do: %{
      "channel" => "telegram",
      "bot" => "default",
      "chat_id" => chat,
      "key" => "telegram:#{chat}"
    }

  defp watch_origin(_), do: %{"channel" => "log"}

  defp watch_id(desc) do
    base =
      desc
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 30)
      |> then(fn s -> if s == "", do: "watch", else: s end)

    taken = Enum.map(Config.watches(), & &1.id)

    if base in taken,
      do: base <> "-" <> Integer.to_string(System.unique_integer([:positive])),
      else: base
  end

  defp agent_cmd(["add", name | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [
          company: :string,
          model: :string,
          prompt: :string,
          description: :string,
          tools: :string,
          can_message: :string,
          can_manage: :string,
          hooks: :string,
          max_iterations: :integer,
          temperature: :float,
          triage_model: :string,
          simple_model: :string,
          utility_model: :string,
          default: :boolean,
          exempt_message_limit: :boolean,
          trust_untrusted_content: :boolean,
          admin: :boolean
        ]
      )

    with :ok <- validate_scope(name, opts[:company]) do
      handle = Company.handle(opts[:company], name)

      agent = %Agent{
        name: handle,
        description: opts[:description],
        model: opts[:model],
        system_prompt: opts[:prompt] || "You are Pepe, a helpful AI agent.",
        tools: parse_tools_opt(opts[:tools]),
        can_message: parse_can_message_opt(opts[:can_message], handle),
        can_manage: parse_can_manage_opt(opts[:admin], opts[:can_manage], handle),
        hooks: parse_hooks_opt(opts[:hooks]),
        max_iterations: opts[:max_iterations] || 12,
        temperature: opts[:temperature],
        triage_model: opts[:triage_model],
        simple_model: opts[:simple_model],
        utility_model: opts[:utility_model],
        exempt_message_limit: opts[:exempt_message_limit] || false,
        trust_untrusted_content: opts[:trust_untrusted_content] || false
      }

      Config.put_agent(agent)
      if opts[:default], do: Config.set_default_agent_for(opts[:company], name)
      admin_note = if opts[:admin], do: " · can administer every agent (--admin)", else: ""
      ok("agent #{green(handle)} saved (tools: #{Enum.join(agent.tools, ", ")})#{admin_note}")
    end
  end

  defp agent_cmd(["list" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string, all: :boolean])
    default = Config.default_agent_name()

    agents = if opts[:all], do: Config.agents(), else: Config.agents_in(opts[:company])

    scope_note =
      cond do
        opts[:all] -> " (all scopes)"
        opts[:company] -> " in company #{opts[:company]}"
        true -> ""
      end

    case agents do
      [] ->
        info(
          "no agents#{scope_note}. add one:\n  mix pepe agent add assistant --model <model> --prompt \"You are helpful.\"#{if opts[:company], do: " --company #{opts[:company]}", else: ""}"
        )

      agents ->
        Enum.each(agents, &print_agent_line(&1, default))
    end
  end

  defp agent_cmd(["remove", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string])
    handle = Company.handle(opts[:company], name)

    if Config.get_agent(handle) do
      Config.delete_agent(handle)
      ok("removed agent #{handle}")
    else
      error("unknown agent: #{handle}")
    end
  end

  defp agent_cmd(["rename", old, new | _]) do
    case Config.rename_agent(old, new) do
      {:error, :not_found} ->
        error("unknown agent: #{old}")

      _ ->
        Pepe.Agent.Workspace.rename(old, new)
        ok("agent #{green(old)} -> #{green(new)} (workspace moved)")
    end
  end

  defp agent_cmd(["route", from, to | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [remove: :boolean, company: :string])
    from = Company.handle(opts[:company], from)
    to = Company.handle(opts[:company], to)

    cond do
      is_nil(Config.get_agent(from)) ->
        error("unknown agent: #{from}")

      is_nil(Config.get_agent(to)) ->
        error("unknown agent: #{to}")

      not Company.same_scope?(from, to) ->
        error("refusing route across companies: #{from} -> #{to}")

      opts[:remove] ->
        Config.disallow_message(from, to)
        ok("removed route #{green(from)} -> #{green(to)}")

      true ->
        Config.allow_message(from, to)
        ok("#{green(from)} -> #{green(to)} (can message)")
    end
  end

  defp agent_cmd(["route" | _]),
    do: error("usage: mix pepe agent route FROM TO [--remove]")

  defp agent_cmd(["manage", from, to | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [remove: :boolean, company: :string])
    from = Company.handle(opts[:company], from)
    to = if to == "*", do: "*", else: Company.handle(opts[:company], to)

    cond do
      is_nil(Config.get_agent(from)) ->
        error("unknown agent: #{from}")

      # `to` may be "*" (all) or a not-yet-created child, so it's not required to exist.
      to != "*" and is_nil(Config.get_agent(to)) ->
        error("unknown agent: #{to}  (use \"*\" for all)")

      opts[:remove] ->
        Config.disallow_manage(from, to)
        ok("revoked: #{green(from)} no longer manages #{green(to)}")

      true ->
        Config.allow_manage(from, to)
        ok("#{green(from)} can now manage #{green(to)}")
    end
  end

  defp agent_cmd(["manage" | _]),
    do: error("usage: mix pepe agent manage ADMIN TARGET [--remove]   (TARGET may be \"*\")")

  defp agent_cmd(["default", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string])
    handle = Company.handle(opts[:company], name)

    if Config.get_agent(handle) do
      Config.set_default_agent_for(opts[:company], name)
      scope = if opts[:company], do: " for #{opts[:company]}", else: ""
      ok("default agent#{scope} -> #{name}")
    else
      error("unknown agent: #{handle}")
    end
  end

  defp agent_cmd(cmd) when cmd in [[], ["help"]] do
    info("""
    mix pepe agent - manage agents

      add NAME [--model M] [--prompt "..."] [--tools t1,t2]
               [--can-message b,c] [--can-manage x,y|*|none] [--admin] [--default] [--company CO]
      list [--company CO | --all]                          list agents (+ routes)
      route FROM TO [--remove] [--company CO]              directed A->B messaging
      manage ADMIN TARGET [--remove] [--company CO]        let ADMIN administer TARGET (or "*")
      rename OLD NEW                                        rename + move its dir
      remove NAME [--company CO]
      default NAME [--company CO]                           set the (scope) default agent

    Capabilities are controlled by an agent's --tools (a capability = having its
    tool - omit --tools to grant every tool); learning is controlled per-conversation
    by a bot's `trainers` list. --admin is shorthand for --can-manage "*" (this agent
    can administer/train every other agent, e.g. the one bootstrap "boss" agent you
    train the rest through) - it does NOT skip the human-approval gate on risky tool
    calls, only widens which agents it's allowed to reach with manage_agent.
    Add --company CO to scope any of these to a company; without it, the root scope.
    """)
  end

  defp agent_cmd(other),
    do: error("unknown: mix pepe agent #{Enum.join(other, " ")}  (try: mix pepe agent help)")

  defp print_agent_line(a, default) do
    mark = if a.name == default, do: " #{green("(default)")}", else: ""
    routes = if a.can_message == [], do: "", else: "\n  -> #{Enum.join(a.can_message, ", ")}"
    manages = manages_line(a.can_manage)

    puts("#{bold(a.name)}#{mark}\n  model: #{a.model || "(default)"}\n  tools: #{Enum.join(a.tools, ", ")}#{routes}#{manages}")
  end

  defp parse_tools_opt(nil), do: Pepe.Tools.names()
  defp parse_tools_opt(""), do: []
  defp parse_tools_opt(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  # Routes are scoped: a bare peer name resolves into this agent's own company.
  defp parse_can_message_opt(v, _handle) when v in [nil, ""], do: []

  defp parse_can_message_opt(str, handle),
    do: str |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> qualify(handle)))

  # --can-manage: omitted -> nil (itself only); "none" -> [] (nobody); "*" or a
  # comma list -> those. Mirrors Pepe.Config.can_manage?/2. --admin is a shortcut
  # for --can-manage "*" (administer every agent) and wins if both are passed -
  # it does NOT touch auto_approve, so risky tool calls this agent makes still go
  # through the normal human authorization gate on any surface with a human to ask.
  defp parse_can_manage_opt(true, _can_manage, _handle), do: ["*"]
  defp parse_can_manage_opt(_admin, nil, _handle), do: nil
  defp parse_can_manage_opt(_admin, "none", _handle), do: []
  defp parse_can_manage_opt(_admin, "*", _handle), do: ["*"]

  defp parse_can_manage_opt(_admin, str, handle),
    do: str |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> qualify(handle)))

  defp parse_hooks_opt(v) when v in [nil, ""], do: []
  defp parse_hooks_opt(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  # Only surface management scope when it's beyond the default (itself only).
  defp manages_line(nil), do: ""
  defp manages_line([]), do: "\n  ⚙ manages: nobody"
  defp manages_line(["*"]), do: "\n  ⚙ manages: all agents"
  defp manages_line(list) when is_list(list), do: "\n  ⚙ manages: #{Enum.join(list, ", ")}"

  ###
  ### run / chat
  ###

  defp run_help do
    info("""
    mix pepe run - one-shot prompt, streams the reply to stdout

      run [AGENT] "your prompt"    # AGENT defaults to the default agent

    Sends "your prompt" to the model right away - there's no interactive
    back-and-forth (see `mix pepe chat` for that).
    """)
  end

  # Run toward an outcome instead of for one turn: work, let an independent reviewer
  # check the result against the criterion, retry until it passes or the cap is hit.
  defp goal_cmd(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [criteria: :string, max_attempts: :integer, judge: :string, agent: :string]
      )

    objective = Enum.join(rest, " ")
    criteria = opts[:criteria]

    cond do
      objective == "" or is_nil(criteria) ->
        error(~s(usage: mix pepe goal "OBJECTIVE" --criteria "how we know it's done" [--max-attempts N] [--judge MODEL] [--agent NAME]))

      not ensure_configured?() ->
        :ok

      true ->
        do_goal_cmd(objective, criteria, opts)
    end
  end

  defp do_goal_cmd(objective, criteria, opts) do
    agent = opts[:agent] || Config.default_agent_name()
    key = "cli-goal:#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, agent)

    loop_opts =
      [
        stream: true,
        on_event: goal_events(),
        authorize: Pepe.Gateways.TUI.authorizer(),
        max_attempts: opts[:max_attempts]
      ]
      |> then(&if(opts[:judge], do: Keyword.put(&1, :judge_model, opts[:judge]), else: &1))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Pepe.Agent.GoalLoop.run(key, objective, criteria, loop_opts) do
      {:ok, :met, _answer, n} ->
        puts("\n✅ Goal met after #{n} attempt(s).")

      {:error, :max_attempts, _answer, missing} ->
        error("\n🛑 Gave up at the attempt cap. Still missing: #{missing}")

      {:error, reason} ->
        error("\n#{inspect(reason)}")
    end
  end

  # The turn's own events render as usual (the console gateway); the goal loop's extra
  # events announce each attempt and the reviewer's verdict.
  defp goal_events do
    stream = Pepe.Gateways.TUI.stream_events()

    fn
      {:goal_attempt, n, max} -> puts("\n── attempt #{n}/#{max} ──")
      {:goal_verdict, true, why} -> puts("\n✅ reviewer: #{why}")
      {:goal_verdict, false, why} -> puts("\n↻ reviewer: #{why}")
      event -> stream.(event)
    end
  end

  defp run_cmd([]), do: error("usage: mix pepe run [AGENT] \"prompt\"")

  defp run_cmd(args), do: if(ensure_configured?(), do: do_run_cmd(args))

  defp do_run_cmd(args) do
    {agent_name, prompt} =
      case args do
        [single] ->
          {nil, single}

        [maybe_agent | rest] ->
          if Config.get_agent(maybe_agent),
            do: {maybe_agent, Enum.join(rest, " ")},
            else: {nil, Enum.join(args, " ")}
      end

    # Reuse the console gateway's rendering + permission prompt for the one-shot.
    case Pepe.Agent.oneshot(agent_name, prompt,
           stream: true,
           on_event: Pepe.Gateways.TUI.stream_events(),
           authorize: Pepe.Gateways.TUI.authorizer()
         ) do
      {:ok, _content, _msgs} -> puts("")
      {:error, reason} -> error("\n#{inspect(reason)}")
    end
  end

  # The interactive console gateway lives in Pepe.Gateways.TUI; just resolve the
  # agent and hand off. `chat` and `tui` both land here.
  defp tui_cmd(args), do: if(ensure_configured?(), do: do_tui_cmd(args))

  defp do_tui_cmd(args) do
    # Accept the agent as a positional (`tui NAME`) or a flag (`tui --agent NAME`),
    # and an optional `--session KEY` to resume/separate console sessions.
    {opts, rest} =
      OptionParser.parse!(args, strict: [agent: :string, session: :string, company: :string])

    raw = opts[:agent] || List.first(rest)
    agent_name = resolve_tui_agent_name(raw, opts[:company])

    case agent_name && Config.get_agent(agent_name) do
      nil ->
        error("no agent. create one with `mix pepe agent add ...` or pass one: mix pepe tui [--agent NAME]")

      agent ->
        Pepe.Gateways.TUI.start(agent.name, opts[:session])
    end
  end

  defp resolve_tui_agent_name(raw, company) do
    cond do
      raw && company -> Company.handle(company, raw)
      raw -> raw
      company -> Config.default_agent_for(company)
      true -> Config.default_agent_name()
    end
  end

  ###
  ### serve / gateway
  ###

  defp serve_help do
    # The "not `mix pepe serve install`" caveat only makes sense when this text is
    # actually shown with the "mix pepe" prefix - substituting it away (standalone
    # mode) would leave a self-contradictory "not `pepe serve install`" right after
    # instructions for running `pepe serve install`. Drop the caveat there instead.
    install_note =
      if Process.get(:pepe_cli_standalone, false) do
        "`install` registers `serve` with launchd (macOS) or systemd --user (Linux) " <>
          "so it survives logout/reboot and restarts itself if it crashes."
      else
        "`install` registers `serve` with launchd (macOS) or systemd --user (Linux)\n" <>
          "so it survives logout/reboot and restarts itself if it crashes - only\n" <>
          "works from the installed pepe binary, not `mix pepe serve install`."
      end

    info("""
    mix pepe serve - run the OpenAI-compatible HTTP API + WebSocket server

      serve [--port 4000] [--tunnel]        run in the foreground
      serve install [--port 4000]           install as a persistent background service
      serve uninstall                       stop and remove the service
      serve status                          is the service installed/running?

    $PORT overrides the default port too; --port takes precedence.

    Tunnel (expose the server publicly via cloudflared, handy for webhooks):
      --tunnel                 quick tunnel with a random trycloudflare.com URL
      --token <TOKEN>          named tunnel with a stable URL you chose in the
                               Cloudflare dashboard (headless; a ${ENV_VAR} ref
                               is interpolated). Add --hostname to print the URL.
      --hostname <HOST>        named tunnel on your own domain after a one-time
                               `cloudflared tunnel login` (no token needed)

    Binds to 0.0.0.0 by default - set a dashboard password (mix pepe dashboard
    password) before exposing it beyond localhost, or bind to 127.0.0.1 and tunnel in.

    Also starts the messaging gateways (Telegram, ...) alongside the endpoint.

    #{install_note}
    """)
  end

  defp serve_service_cmd(sub, rest) do
    result =
      case sub do
        "install" ->
          {opts, _} = OptionParser.parse!(rest, strict: [port: :integer])
          Pepe.ServiceInstall.install(opts)

        "uninstall" ->
          Pepe.ServiceInstall.uninstall()

        "status" ->
          Pepe.ServiceInstall.status()
      end

    case result do
      {:ok, msg} -> ok(msg)
      {:error, msg} -> error(msg)
    end
  end

  defp serve_cmd(rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [tunnel: :boolean, hostname: :string, token: :string])
    port = PepeWeb.Endpoint.config(:http)[:port] || 4000

    ok("Pepe serving on http://localhost:#{port}  (override with PORT=NNNN)")

    info("""
      OpenAI API : POST http://localhost:#{port}/v1/chat/completions
      Models     : GET  http://localhost:#{port}/v1/models
      Health     : GET  http://localhost:#{port}/health
      WebSocket  : ws://localhost:#{port}/socket/websocket  (topic agent:default)
    """)

    dashboard_posture()
    if opts[:tunnel] || opts[:hostname] || opts[:token], do: start_tunnel(port, opts)
    Process.sleep(:infinity)
  end

  # Report (and, where risky, warn about) how the dashboard is exposed. The per-request
  # NetworkGuard is the actual enforcement; this just makes the posture visible at boot.
  defp dashboard_posture do
    ip = PepeWeb.Endpoint.config(:http)[:ip]
    loopback? = ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

    cond do
      Config.dashboard_auth_required?() ->
        ok("dashboard: password protected (login required)")

      loopback? ->
        info(dim("   dashboard: open on localhost only; remote clients are blocked until you set a password"))

      true ->
        info("")
        info(yellow("   dashboard: bound to a public interface with NO password."))
        info(yellow("   Remote access is blocked (fail-closed). To allow it:"))

        info(yellow("     mix pepe dashboard password '<pass>'   (or bind to 127.0.0.1 and tunnel in)"))
    end
  end

  # Expose the running server through a Cloudflare tunnel and print the public URL. A
  # quick tunnel (random URL) by default; a stable named tunnel when --token or
  # --hostname is given. --token is a secret, so a ${ENV_VAR} reference is interpolated.
  defp start_tunnel(port, opts) do
    if Pepe.Tunnel.available?() do
      token = opts[:token] && Config.interpolate(opts[:token])
      hostname = opts[:hostname]

      info(dim("   #{tunnel_opening_line(token, hostname)}"))

      Pepe.Tunnel.open(port, &print_tunnel_url/1, token: token, hostname: hostname)
    else
      info(yellow("   --tunnel needs cloudflared. #{cloudflared_install_hint()}"))
    end
  end

  defp tunnel_opening_line(token, hostname) do
    cond do
      token && hostname -> "opening a named tunnel to #{hostname} via cloudflared (token)..."
      token -> "opening a named tunnel via cloudflared (token)..."
      hostname -> "opening a named tunnel to #{hostname} via cloudflared..."
      true -> "opening a public tunnel via cloudflared..."
    end
  end

  defp cloudflared_install_hint do
    case :os.type() do
      {:unix, :darwin} ->
        "Install it: brew install cloudflared"

      {:unix, :linux} ->
        asset = "cloudflared-linux-#{linux_arch()}.deb"

        "Install it:\n" <>
          "     curl -LO https://github.com/cloudflare/cloudflared/releases/latest/download/#{asset}\n" <>
          "     sudo dpkg -i #{asset}"

      _ ->
        "See https://pkg.cloudflare.com/ for install instructions."
    end
  end

  defp linux_arch do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "aarch64" <> _ -> "arm64"
      "arm" <> _ -> "arm64"
      _ -> "amd64"
    end
  end

  defp print_tunnel_url(:connected) do
    info("")
    ok("Tunnel connected. Reachable at the public hostname configured for this tunnel in Cloudflare.")
    tunnel_password_warning()
  end

  defp print_tunnel_url(url) when is_binary(url) do
    info("")
    ok("Public URL: #{url}")
    tunnel_password_warning()
  end

  defp tunnel_password_warning do
    unless Config.dashboard_auth_required?() do
      info(yellow("   the dashboard is fail-closed over the tunnel until you set a password: mix pepe dashboard password '<pass>'"))
    end
  end

  defp gateway_cmd(["whatsapp", "list" | _]) do
    case Config.webhooks() |> Enum.filter(fn {_s, e} -> e["provider"] == "whatsapp" end) do
      [] ->
        info("no WhatsApp connections. Add one:\n  mix pepe gateway whatsapp add support --agent <handle>")

      conns ->
        Enum.each(conns, &print_whatsapp_conn_line/1)
    end
  end

  defp gateway_cmd(["whatsapp", "add", slug | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          agent: :string,
          company: :string,
          mode: :string,
          phone_number_id: :string,
          access_token: :string,
          app_secret: :string,
          verify_token: :string,
          trainers: :string,
          ttl_min: :integer,
          ephemeral: :boolean,
          commands: :boolean
        ]
      )

    mode = if opts[:mode] == "admin", do: "admin", else: "support"

    cond do
      Config.webhook_exists?(slug) ->
        error("a webhook connection named #{slug} already exists")

      is_nil(opts[:agent]) ->
        error("whatsapp add needs --agent HANDLE (who answers)")

      is_nil(opts[:phone_number_id]) ->
        error("whatsapp add needs --phone-number-id (from the Meta app)")

      true ->
        save_whatsapp_connection(slug, mode, opts)
    end
  end

  # support defaults: never learn + ephemeral; admin: learns + persisted.
  defp gateway_cmd(["whatsapp", "set-agent", slug, agent | _]) do
    case Config.get_webhook(slug) do
      nil ->
        error("unknown whatsapp connection: #{slug}")

      e ->
        Config.put_webhook(slug, Map.put(e, "agent", agent))
        ok("#{green(slug)} -> agent #{agent}")
    end
  end

  defp gateway_cmd(["whatsapp", "remove", slug | _]) do
    if Config.webhook_exists?(slug) do
      Config.delete_webhook(slug)
      ok("#{green(slug)} removed")
    else
      error("unknown whatsapp connection: #{slug}")
    end
  end

  defp gateway_cmd(["whatsapp" | _]) do
    info("""
    mix pepe gateway whatsapp - WhatsApp Cloud API connections (webhook-based)

      add SLUG --agent HANDLE --phone-number-id ID [--company CO] [--mode support|admin]
               [--access-token ${ENV}] [--app-secret ${ENV}] [--verify-token X]
               [--trainers none|*|id1,id2] [--ttl-min N] [--ephemeral] [--commands]
      list                     list connections + their Callback URLs
      set-agent SLUG HANDLE     rebind a connection to another agent
      remove SLUG               delete a connection

    Served by `mix pepe serve`. Register the printed Callback URL in your Meta app.
    """)
  end

  defp gateway_cmd(["telegram", "list" | _]) do
    case Config.telegram_bots() do
      [] ->
        info(dim("no telegram bots configured. add one: mix pepe gateway telegram setup"))

      bots ->
        info(bold("✦ Telegram bots") <> dim(" - one poller per bot, each bound to an agent"))

        Enum.each(bots, &print_telegram_bot_line/1)
    end
  end

  defp gateway_cmd(["telegram", "add", name | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          token: :string,
          agent: :string,
          trainers: :string,
          heartbeat_minutes: :integer,
          heartbeat_hours: :string,
          progress: :string
        ]
      )

    cond do
      name == "default" ->
        error("the default bot is managed via: mix pepe gateway telegram setup")

      is_nil(opts[:token]) ->
        error("telegram add needs --token (create a bot with @BotFather)")

      true ->
        map =
          %{
            "bot_token" => opts[:token],
            "agent" => opts[:agent],
            "trainers" => parse_trainers(opts[:trainers]),
            "heartbeat_minutes" => opts[:heartbeat_minutes],
            "heartbeat_active_hours" => parse_hour_window(opts[:heartbeat_hours]),
            "tool_progress" => valid_progress(opts[:progress])
          }
          |> reject_nil_values()

        Config.put_telegram_bot(name, map)
        ok("telegram bot #{green(name)} -> agent #{opts[:agent] || "(default)"}")
        info(dim("run/refresh with: mix pepe gateway telegram  (or restart serve)"))
    end
  end

  defp gateway_cmd(["telegram", "remove", name | _]) do
    cond do
      name == "default" ->
        error("the default bot is managed via: mix pepe gateway telegram setup")

      is_nil(Config.telegram_bot(name)) ->
        error("unknown telegram bot: #{name}")

      true ->
        Config.delete_telegram_bot(name)
        ok("#{green(name)} removed")
    end
  end

  defp gateway_cmd(["telegram" | _]) do
    active = Config.telegram_bots() |> Enum.filter(&Pepe.Gateways.Telegram.bot_active?/1)

    case active do
      [] ->
        error("no Telegram bot token configured. Run: mix pepe gateway telegram setup")

      bots ->
        names = Enum.map_join(bots, ", ", & &1["name"])
        ok("Telegram gateway running (#{length(bots)} bot(s): #{names}). Press Ctrl-C to stop.")
        Process.sleep(:infinity)
    end
  end

  defp gateway_cmd(cmd) when cmd in [[], ["help"]] do
    info("""
    mix pepe gateway - messaging gateways

      telegram setup              configure the DEFAULT bot (token, allowlists, agent)
      telegram add NAME --token T [--agent A] [--trainers id1,id2]
                          [--heartbeat-minutes N] [--heartbeat-hours 8-22]
                                  add another bot bound to an agent
                                  (--trainers: who it learns from; omit=everyone, none=nobody)
      telegram list               list configured bots
      telegram remove NAME        delete a named bot
      telegram                    run the gateway - one poller per bot (long-polling)
    """)
  end

  defp gateway_cmd(_),
    do: error("usage: mix pepe gateway telegram [setup|add|list|remove]  (or: help)")

  defp print_whatsapp_conn_line({slug, e}) do
    co = e["company"] || "root"
    puts("#{bold(slug)} [#{e["mode"] || "support"}] -> #{e["agent"] || "(default)"}")
    puts(dim("   #{webhook_host()}/webhooks/#{co}/whatsapp/#{slug}"))
  end

  defp save_whatsapp_connection(slug, mode, opts) do
    support? = mode == "support"

    entry =
      %{
        "provider" => "whatsapp",
        "company" => blank_default(opts[:company], nil),
        "agent" => opts[:agent],
        "mode" => mode,
        "commands" => Keyword.get(opts, :commands, mode == "admin"),
        "trainers" => parse_trainers(opts[:trainers]) || if(support?, do: [], else: nil),
        "ephemeral" => Keyword.get(opts, :ephemeral, support?),
        "session_ttl_min" => opts[:ttl_min],
        "config" =>
          %{
            "phone_number_id" => opts[:phone_number_id],
            "access_token" => opts[:access_token] || "${WA_TOKEN_#{String.upcase(slug)}}",
            "app_secret" => opts[:app_secret] || "${WA_APP_SECRET_#{String.upcase(slug)}}",
            "verify_token" => opts[:verify_token] || slug
          }
          |> reject_nil_values()
      }
      |> reject_nil_values()

    Config.put_webhook(slug, entry)
    co = entry["company"] || "root"
    ok("whatsapp #{green(slug)} [#{mode}] -> agent #{opts[:agent]}")
    info("register this Callback URL in the Meta app:")
    info(bold("   #{webhook_host()}/webhooks/#{co}/whatsapp/#{slug}"))
    info(dim("   verify token: #{entry["config"]["verify_token"]}"))
  end

  defp print_telegram_bot_line(b) do
    state = if Pepe.Gateways.Telegram.bot_active?(b), do: green("active"), else: dim("inactive")
    info("\n#{bold(b["name"])}  [#{state}]")
    info(dim("   agent:    #{b["agent"] || "(default)"}"))
    info(dim("   token:    #{token_hint(b["bot_token"])}"))
    info(dim("   learns from: #{trainers_hint(b["trainers"])}"))
  end

  defp token_hint(nil), do: "(none)"
  defp token_hint("${" <> _ = env), do: env
  defp token_hint(t), do: String.slice(to_string(t), 0, 6) <> "..."

  defp trainers_hint(nil), do: "everyone (default)"
  defp trainers_hint([]), do: "no one"
  defp trainers_hint(["*"]), do: "everyone"
  defp trainers_hint(list) when is_list(list), do: Enum.join(list, ", ")
  defp trainers_hint(_), do: "everyone"

  # --trainers: omitted -> nil (default: everyone); "*" -> ["*"] (everyone, explicit);
  # "none"/"" -> [] (no one); "id1,id2" -> [id1, id2] (only those user ids).
  defp valid_progress(m) when m in ~w(reaction ambient off verbose), do: m
  defp valid_progress(_), do: nil

  defp parse_hour_window(nil), do: nil

  defp parse_hour_window(str) do
    case String.split(str, "-") do
      [a, b] ->
        with {start, ""} <- Integer.parse(String.trim(a)),
             {finish, ""} <- Integer.parse(String.trim(b)) do
          [start, finish]
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp webhook_host, do: System.get_env("PEPE_PUBLIC_URL") || "https://YOUR_HOST"

  defp parse_trainers(nil), do: nil
  defp parse_trainers(str) when str in ["", "none"], do: []
  defp parse_trainers("*"), do: ["*"]

  defp parse_trainers(str) do
    str
    |> String.split(",")
    |> Enum.flat_map(fn s ->
      case Integer.parse(String.trim(s)) do
        {n, _} -> [n]
        :error -> []
      end
    end)
  end

  # Interactive Telegram config - token, optional agent, optional chat allowlist.
  defp telegram_setup do
    current = Config.telegram()

    info(bold("Telegram gateway setup"))
    info(dim("Create a bot with @BotFather (https://t.me/BotFather), then paste its token.\n"))

    token =
      case Owl.IO.input(
             label: "Bot token (or ${ENV_VAR}; blank keeps current):",
             secret: true,
             optional: true
           ) do
        blank when blank in [nil, ""] -> current["bot_token"]
        value -> value
      end

    if presence(token) do
      base = %{
        "bot_token" => token,
        "allowed_chats" => prompt_id_list("Allowed chat ids", current["allowed_chats"] || []),
        "allowed_users" => prompt_id_list("Allowed user ids", current["allowed_users"] || []),
        "require_mention" => prompt_require_mention(current),
        "agent" => prompt_gateway_agent(current["agent"])
      }

      base |> reject_nil_values() |> Config.put_telegram()

      ok("Telegram configured.")
      info(dim("Start it with:  mix pepe gateway telegram"))
    else
      error("a bot token is required; aborting.")
    end
  end

  defp prompt_gateway_agent(current) do
    case agent_names() do
      [] ->
        current

      names ->
        default_label = "(use the default agent)"

        case Pepe.TUI.select([default_label | names],
               label: bold("Which agent answers on Telegram?")
             ) do
          ^default_label -> nil
          name -> name
        end
    end
  end

  defp prompt_id_list(label, current) do
    hint =
      if current == [], do: "blank = no restriction", else: "current: #{Enum.join(current, ", ")}"

    case Owl.IO.input(label: "#{label}, comma-separated (#{hint}):", optional: true) do
      blank when blank in [nil, ""] ->
        current

      str ->
        str
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> Integer.parse()))
        |> Enum.flat_map(fn
          {n, _} -> [n]
          :error -> []
        end)
    end
  end

  defp prompt_require_mention(current) do
    Owl.IO.confirm(
      message: "In group chats, only reply when the bot is @mentioned?",
      default: current["require_mention"] != false
    )
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  ###
  ### misc
  ###

  # Guided, end-to-end onboarding: provider -> auth -> model -> agent -> tools, then
  # everything is saved and set as default. The interactive controls come from
  # Owl (select / multiselect / input) so we don't hand-roll a TUI.
  # First run walks the full wizard; later runs open a menu to (re)configure parts.
  defp setup do
    if configured?() do
      announce_backup(Config.backup())
      Config.load() |> Config.save()
      config_menu()
    else
      maybe_choose_home()
      Config.load() |> Config.save()
      first_run_setup()
    end
  end

  defp announce_backup(nil), do: :ok

  defp announce_backup(bak) do
    info(
      dim("backed up your config to #{Config.short_path(bak)}  (restore: cp #{Config.short_path(bak)} #{Config.short_path(Config.path())})")
    )
  end

  # First run only: show where everything will be stored, and let the user relocate it.
  # A chosen path is set for this process and offered for their shell profile so future
  # runs (which read PEPE_HOME) find it - it can't live in the config, since the config
  # is what lives at that path.
  defp maybe_choose_home do
    current = Config.home()
    info(bold("Storage location"))
    info("Pepe keeps its config, data and workspaces under:")
    info("  " <> green(Config.short_path(current)) <> dim("  (#{current})"))

    case Owl.IO.input(label: "Press Enter to use it, or type another folder:", optional: true) |> presence() do
      nil ->
        :ok

      typed ->
        expanded = Path.expand(typed)

        if expanded != current do
          File.mkdir_p!(expanded)
          System.put_env("PEPE_HOME", expanded)
          ok("storing everything under #{green(Config.short_path(expanded))}")
          offer_persist_home(expanded)
        end
    end

    info("")
  end

  defp print_storage_summary do
    info("\n" <> bold("Where Pepe keeps everything") <> dim(" (all hand-editable):"))
    info("  config : " <> Config.short_path(Config.path()))
    info("  data   : " <> Config.short_path(Path.join(Config.home(), "data")))
    info("  agents : " <> Config.short_path(Path.join(Config.home(), "agents")))
  end

  defp offer_persist_home(path) do
    line = ~s(export PEPE_HOME="#{path}")

    if ask_yes?("Add this to your shell profile so future runs use it?\n  " <> dim(line)) do
      case persist_env_line(line) do
        {:ok, rc} ->
          ok("added to #{Config.short_path(rc)} - open a new shell, or run: source #{Config.short_path(rc)}")

        :error ->
          info(dim("couldn't find a shell profile - set it yourself: #{line}"))
      end
    else
      info(dim("remember to set it, or future runs use the default location: #{line}"))
    end
  end

  # Idempotent append of an env line to the user's shell rc (never duplicates it).
  defp persist_env_line(line) do
    case shell_rc() do
      nil ->
        :error

      rc ->
        body =
          case File.read(rc) do
            {:ok, b} -> b
            _ -> ""
          end

        unless String.contains?(body, line) do
          File.write!(rc, "\n# pepe storage location\n#{line}\n", [:append])
        end

        {:ok, rc}
    end
  end

  defp shell_rc do
    home = System.user_home!()
    shell = System.get_env("SHELL") || ""

    cond do
      String.contains?(shell, "zsh") -> Path.join(home, ".zshrc")
      String.contains?(shell, "bash") -> Path.join(home, ".bashrc")
      File.exists?(Path.join(home, ".zshrc")) -> Path.join(home, ".zshrc")
      File.exists?(Path.join(home, ".bashrc")) -> Path.join(home, ".bashrc")
      true -> nil
    end
  end

  # A model connection is the one thing every run/chat needs; offer setup right there
  # (or, with no TTY, say what to run) instead of a bare "not configured" failure.
  defp ensure_configured? do
    cond do
      configured?() ->
        true

      interactive?() ->
        info(yellow("Pepe isn't set up yet") <> dim(" (no model connection)."))

        if ask_yes?("Run setup now?") do
          first_run_setup()
          configured?()
        else
          info("Run " <> bold("mix pepe setup") <> " when you're ready.")
          false
        end

      true ->
        error("not configured - run `pepe setup` first (it needs a model connection)")
        false
    end
  end

  defp interactive?, do: match?({:ok, _}, :io.columns())

  defp ask_yes?(question) do
    case Owl.IO.input(label: question <> " [Y/n]", optional: true) do
      v when v in [nil, ""] -> true
      v -> String.downcase(String.trim(v)) in ["y", "yes", "s", "sim"]
    end
  end

  defp configured?, do: Config.models() != [] or Config.agents() != []

  # Subsequent runs: pick what to add/reconfigure instead of redoing every step.
  defp config_menu do
    info(bold("Pepe setup") <> dim(" - you're already configured. What do you want to do?\n"))

    options = [
      {:model, "Model connection - add or switch the default"},
      {:agent, "Agent - add or set the default"},
      {:channel, "Channels - Telegram, Slack, Discord, WhatsApp, ..."},
      {:dashboard, "Dashboard - password and remote access"},
      {:migrate, "Import from another runtime - existing agents and models"},
      {:plugin, "Plugins - install a channel or tool"},
      {:privacy, "Privacy - redact PII before it reaches a model"},
      {:language, "Language for system messages"},
      {:timezone, "Default timezone for scheduled tasks"},
      {:sandbox, "Sandbox - isolate the shell tools (bash / run_script)"},
      {:full, "Run the full guided setup"},
      {:done, "Done"}
    ]

    {action, _label} =
      Pepe.TUI.select(options,
        label: bold("Configure:"),
        render_as: fn {_a, label} -> label end
      )

    handle_config_action(action)
  end

  defp handle_config_action(:done), do: ok("Done.")
  defp handle_config_action(:full), do: first_run_setup()
  defp handle_config_action(:model), do: then_menu(fn -> model_cmd([]) end)
  defp handle_config_action(:agent), do: then_menu(fn -> add_agent() end)
  defp handle_config_action(:channel), do: then_menu(&setup_channel/0)
  defp handle_config_action(:dashboard), do: then_menu(&setup_dashboard/0)
  defp handle_config_action(:migrate), do: then_menu(&setup_migrate/0)
  defp handle_config_action(:plugin), do: then_menu(&setup_plugin/0)
  defp handle_config_action(:privacy), do: then_menu(&setup_privacy/0)
  defp handle_config_action(:language), do: then_menu(&setup_language/0)
  defp handle_config_action(:timezone), do: then_menu(&setup_timezone/0)
  defp handle_config_action(:sandbox), do: then_menu(&setup_sandbox/0)

  defp then_menu(fun) do
    fun.()
    config_menu()
  end

  # --- setup: channels --------------------------------------------------------------

  defp setup_channel do
    options = [{"telegram", "Telegram (bot poller)"} | Enum.map(Pepe.Webhooks.providers(), &{&1, channel_label(&1)})]
    {which, _} = Pepe.TUI.select(options, label: bold("\nWhich channel?"), render_as: fn {_a, l} -> l end)
    if which == "telegram", do: telegram_setup(), else: setup_webhook_connection(which)
  end

  defp channel_label(name) do
    mod = Pepe.Webhooks.provider(name)
    # Code.ensure_loaded? first: function_exported?/3 is false for a not-yet-loaded
    # module, which under `mix pepe` (lazy loading) would silently skip the label.
    label = if Code.ensure_loaded?(mod) and function_exported?(mod, :label, 0), do: mod.label(), else: name
    "#{label} (webhook)"
  end

  defp setup_webhook_connection(provider) do
    mod = Pepe.Webhooks.provider(provider)
    # Code.ensure_loaded? first (see channel_label): otherwise, under `mix pepe`,
    # the provider module isn't loaded yet, function_exported?/3 returns false, and
    # the schema comes back empty - so NO credential fields get prompted and a
    # broken, empty-config connection is saved. Embedded releases preload modules
    # so they dodged this, but the guard was still wrong.
    schema =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :config_schema, 0),
        do: mod.config_schema(),
        else: []

    slug = Owl.IO.input(label: "Connection name (slug):", optional: true) |> blank_default(provider)
    agent = pick_setup_agent()

    config =
      Enum.reduce(schema, %{}, fn field, acc ->
        case prompt_config_field(field) do
          "" -> acc
          value -> Map.put(acc, field["key"], value)
        end
      end)

    Config.put_webhook(slug, %{"provider" => provider, "agent" => agent, "mode" => "support", "config" => config})
    ok("channel #{green(provider)} connected as #{slug}")
    info(dim("Paste this into #{provider} as its webhook URL:\n  #{webhook_host()}/webhooks/root/#{provider}/#{slug}"))
  end

  # A channel config field is required unless it's a `select` (those carry a
  # default) or explicitly opts out with `"required" => false`. So every
  # credential/id (bot token, signing secret, ...) must be filled - a blank one
  # would silently create a broken, non-authenticating connection.
  @doc false
  def required_config_field?(field), do: field["type"] != "select" and field["required"] != false

  # A `${ENV_VAR}` reference counts as filled (that's how secrets are meant to be
  # given). On a blank required field, re-prompt with a clear, localized message.
  defp prompt_config_field(field) do
    required? = required_config_field?(field)
    hint = if field["type"] == "secret", do: dim(gettext(" (a ${ENV_VAR} reference is fine)")), else: ""
    tag = if required?, do: "", else: dim(gettext(" (optional)"))
    value = Owl.IO.input(label: "#{field["label"]}#{tag}#{hint}:", optional: true) |> to_string() |> String.trim()

    cond do
      value != "" ->
        value

      required? ->
        error(gettext("\"%{field}\" is required. Please enter it (a ${ENV_VAR} reference is fine).", field: field["label"]))
        prompt_config_field(field)

      true ->
        ""
    end
  end

  defp pick_setup_agent do
    case agent_names() do
      [] ->
        Config.default_agent_name()

      names ->
        {agent, _} = Pepe.TUI.select(Enum.map(names, &{&1, &1}), label: "Which agent handles it?", render_as: fn {_a, l} -> l end)
        agent
    end
  end

  # --- setup: dashboard, migrate, plugins, privacy ----------------------------------

  defp setup_dashboard do
    dashboard_cmd([])

    if not Config.dashboard_auth_required?() and Owl.IO.confirm(message: "\nSet a dashboard password now?", default: false) do
      pass = Owl.IO.input(label: "Password (or a ${ENV_VAR} reference):", secret: true)
      if pass not in [nil, ""], do: dashboard_cmd(["password", pass])
    end
  end

  defp setup_migrate do
    case detected_sources() do
      [] ->
        info("No importable install found in the default locations.")
        info(dim("Point at one: mix pepe migrate <source> --from PATH"))

      detected ->
        {src, _} = Pepe.TUI.select(Enum.map(detected, &{&1, &1}), label: bold("\nImport from:"), render_as: fn {_a, l} -> l end)
        run_migrate(src, dry_run: true)
        if Owl.IO.confirm(message: "\nApply this import?", default: false), do: run_migrate(src, [])
    end
  end

  defp detected_sources, do: Pepe.Migrate.detected()

  defp setup_plugin do
    src = Owl.IO.input(label: "Plugin source (a local path, a .tar.gz, or a GitHub repo URL):", optional: true)
    if src not in [nil, ""], do: plugin_install(src, force: false)
  end

  defp setup_privacy do
    info("Privacy hooks redact PII before it reaches a model.")
    info(dim("Configure them in the dashboard (Privacy tab), or with: mix pepe hooks"))

    if Owl.IO.confirm(message: "Show the current hooks now?", default: false), do: hooks_cmd(["list"])
  end

  defp first_run_setup do
    info(bold("Welcome to Pepe setup") <> " - let's get you ready.\n")
    setup_language()

    info("\n" <> bold("Step 1/2 · Model connection"))

    case choose_provider() do
      {nil, _, _} ->
        error("no provider selected; setup aborted.")

      {base_url, api_key, oauth} ->
        name =
          Owl.IO.input(label: "Name this connection:", optional: true)
          |> blank_default(default_conn_name(base_url))
          |> ensure_unique(model_names(), "model connection")

        case pick_model(base_url, api_key) do
          nil ->
            error("no model selected; setup aborted.")

          model_id ->
            Config.put_model(%Model{
              name: name,
              base_url: base_url,
              api_key: api_key,
              oauth: oauth,
              model: model_id,
              api: api_for(base_url)
            })

            Config.set_default_model(name)
            ok("model #{green(name)} -> #{model_id}")

            info("\n" <> bold("Step 2/2 · Agent"))
            add_agent(true)
            maybe_setup_telegram()
            maybe_setup_migrate()
            maybe_setup_dashboard()
            print_storage_summary()
            info("\n" <> green("✓ All set!") <> "  Try:  " <> bold("pepe run \"hello\""))
            info(dim("More anytime: rerun " <> bold("mix pepe setup") <> dim(" for channels, plugins, privacy and dashboard.")))
        end
    end
  end

  @locales [
    {"en", "English"},
    {"pt_BR", "Português (Brasil)"},
    {"pt_PT", "Português (Portugal)"},
    {"es", "Español"}
  ]

  defp setup_language do
    {code, _label} =
      Pepe.TUI.select(@locales,
        label: bold("Language for system messages") <> dim(" (current: #{Config.locale()})"),
        render_as: fn {_code, label} -> label end
      )

    Config.set_locale(code)
    # Apply immediately so the rest of the wizard (and every menu hint) is shown
    # in the language just picked, not the previous one.
    Config.put_locale()
    ok(gettext("language set to %{code}", code: code))
  end

  # Default timezone for scheduled tasks that don't name their own. Free-text so any
  # IANA zone works ("America/Sao_Paulo", "Europe/Berlin", ...); a task can still
  # override it. Blank keeps the current value.
  defp setup_timezone do
    tz =
      Owl.IO.input(
        label:
          "Default timezone for scheduled tasks" <>
            dim(" (current: #{Config.default_timezone()})") <> ":",
        optional: true
      )
      |> blank_default(Config.default_timezone())

    case DateTime.now(tz) do
      {:ok, _} ->
        Config.set_default_timezone(tz)
        ok("timezone -> #{tz}")

      _ ->
        error("unknown timezone: #{tz} - keeping #{Config.default_timezone()}")
    end
  end

  # Choose how the shell tools (bash/run_script) run. Guardrails (blocking catastrophic
  # commands) and the approval gate are always on; this adds strong OS-level isolation.
  defp setup_sandbox do
    info(
      dim(
        "The shell tools always run behind the approval gate and guardrails. " <>
          "A sandbox adds real isolation, so an auto-approved agent can't touch the host."
      )
    )

    options =
      [
        {"none", "None - run on the host (approval + guardrails still apply)"},
        {"docker", "Docker/Podman container - portable (Linux/macOS/Windows)"}
      ] ++
        case :os.type() do
          {:unix, :darwin} -> [{"macos", "sandbox-exec (macOS, lightweight)"}]
          {:unix, _} -> [{"firejail", "firejail (Linux, lightweight)"}]
          _ -> []
        end

    {kind, _} =
      Pepe.TUI.select(options,
        label: bold("Sandbox for the shell tools:"),
        render_as: fn {_k, label} -> label end
      )

    case kind do
      "none" ->
        Config.set_sandbox(nil)
        ok("sandbox -> none (host)")

      _ ->
        case Pepe.Sandbox.install_wrapper(kind) do
          {:ok, path} ->
            Config.set_sandbox(path)
            ok("sandbox -> #{kind}  (#{path})")
            check_sandbox_tool(kind)

          {:error, _} ->
            error("could not set up the #{kind} wrapper")
        end
    end
  end

  # Warn (don't auto-install) if the chosen sandbox's tool isn't on PATH.
  defp check_sandbox_tool(kind) do
    {tool, hint} =
      case kind do
        "docker" -> {"docker", "install Docker Desktop / Podman, or set PEPE_SANDBOX_RUNTIME=podman"}
        "firejail" -> {"firejail", "install it, e.g. `sudo apt install firejail`"}
        "macos" -> {"sandbox-exec", "it ships with macOS; nothing to install"}
        _ -> {nil, nil}
      end

    cond do
      is_nil(tool) -> :ok
      System.find_executable(tool) -> ok("#{tool} is available")
      true -> error("#{tool} is not on PATH yet - #{hint}")
    end
  end

  # Add an agent bound to the current default model connection. The `primary?`
  # agent - the one created on first setup - is the owner's own agent, so it's born
  # omnipotent: every tool, super-admin over all agents, and auto-approval of all
  # tools (no permission prompts), so it can do anything via chat from the start.
  defp add_agent(primary? \\ false) do
    # The very first agent is always the primary (omnipotent) one, whatever path
    # created it.
    primary? = primary? or agent_names() == []

    agent_name =
      Owl.IO.input(label: "Agent name:", optional: true)
      |> blank_default("assistant")
      |> ensure_unique(agent_names(), "agent")

    system_prompt =
      Owl.IO.input(label: "System prompt:", optional: true)
      |> blank_default("You are Pepe, a helpful AI agent.")

    tools = if primary?, do: Pepe.Tools.names(), else: pick_tools()

    Config.put_agent(%Agent{
      name: agent_name,
      model: Config.default_model_name(),
      system_prompt: system_prompt,
      tools: tools,
      auto_approve: if(primary?, do: ["*"], else: []),
      can_manage: if(primary?, do: ["*"], else: nil),
      max_iterations: 12
    })

    Config.set_default_agent(agent_name)

    if primary? do
      ok("agent #{green(agent_name)} - full access (all tools, super-admin, no prompts)")
    else
      ok("agent #{green(agent_name)} (tools: #{Enum.join(tools, ", ")})")
    end

    :ok
  end

  defp pick_tools do
    case Pepe.TUI.multiselect(Pepe.Tools.names(),
           label: bold("Select tools") <> dim(" (numbers, space/comma separated; blank = all):"),
           render_as: &tool_render/1
         ) do
      [] -> Pepe.Tools.names()
      picked -> picked
    end
  end

  defp maybe_setup_migrate do
    case detected_sources() do
      [] ->
        :ok

      detected ->
        if Owl.IO.confirm(message: "\nFound an existing #{Enum.join(detected, " / ")} setup. Import it?", default: false),
          do: setup_migrate()
    end
  end

  defp maybe_setup_dashboard do
    if not Config.dashboard_auth_required?() and
         Owl.IO.confirm(message: "\nSet a dashboard password (needed to reach it from another machine)?", default: false) do
      pass = Owl.IO.input(label: "Password (or a ${ENV_VAR} reference):", secret: true)
      if pass not in [nil, ""], do: dashboard_cmd(["password", pass])
    end
  end

  defp maybe_setup_telegram do
    if Owl.IO.confirm(message: "\nSet up a Telegram gateway now?", default: false) do
      telegram_setup()
    end
  end

  defp blank_default(nil, default), do: default
  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: value

  # Warn before clobbering an existing entry: offer to replace it or pick another
  # name. `kind` is "model connection" / "agent" for the message.
  defp ensure_unique(name, existing, kind) do
    if name in existing do
      info(dim("A #{kind} named #{green(name)}#{dim(" already exists.")}"))

      if Owl.IO.confirm(message: "Replace it?", default: false) do
        name
      else
        Owl.IO.input(label: "Pick a different name:")
        |> ensure_unique(existing, kind)
      end
    else
      name
    end
  end

  defp model_names, do: Enum.map(Config.models(), & &1.name)
  defp agent_names, do: Enum.map(Config.agents(), & &1.name)

  # CLI: qualify a bare peer/target into the same company as `handle`; leave the "*"
  # wildcard and already-qualified handles untouched.
  defp qualify("*", _handle), do: "*"
  defp qualify(name, handle), do: Company.qualify(name, handle)

  # Validate a name (and optional --company target) before creating something in it:
  # the bare name must be a legal segment and, when given, the company must exist.
  # Prints and returns :error on failure, :ok otherwise. `nil` company = root scope.
  defp validate_scope(name, company) do
    cond do
      not Company.valid_name?(name) ->
        error("invalid name #{inspect(name)} - use letters, digits, - and _ only (no \"/\")")
        :error

      company && not Config.company_exists?(company) ->
        error("unknown company: #{company} - create it with: mix pepe company add #{company}")
        :error

      true ->
        :ok
    end
  end

  # Suggest a connection name from the host (api.openai.com -> "openai").
  defp default_conn_name(base_url) do
    host = URI.parse(base_url).host || "model"

    host
    |> String.split(".")
    |> Enum.reject(&(&1 in ["api", "www"]))
    |> List.first()
    |> Kernel.||("model")
  end

  defp tool_render(name) do
    case Pepe.Tools.get(name) do
      nil ->
        name

      mod ->
        %{"function" => %{"description" => desc}} = mod.spec()
        [name, dim("  - " <> String.slice(desc, 0, 48))]
    end
  end

  defp config_cmd(_) do
    info("config file: #{Config.path()}")
    info("default model: #{Config.default_model_name() || "(none)"}")
    info("default agent: #{Config.default_agent_name() || "(none)"}")
    info("models: #{Config.models() |> Enum.map_join(", ", & &1.name)}")
    info("agents: #{Config.agents() |> Enum.map_join(", ", & &1.name)}")
  end

  ###
  ### dashboard (auth)
  ###

  defp dashboard_cmd(["password", "--clear"]) do
    cfg = Config.load()
    dash = cfg |> Map.get("dashboard", %{}) |> Map.delete("password")
    Config.save(Map.put(cfg, "dashboard", dash))

    if System.get_env("PEPE_DASHBOARD_PASSWORD") do
      ok("cleared the config password (but PEPE_DASHBOARD_PASSWORD is still set in the environment)")
    else
      ok("dashboard password cleared - the dashboard is open again")
    end
  end

  defp dashboard_cmd(["password", value]) when is_binary(value) do
    cfg = Config.load()
    dash = cfg |> Map.get("dashboard", %{}) |> Map.put("password", value)
    Config.save(Map.put(cfg, "dashboard", dash))
    ok("dashboard password set - the dashboard now requires signing in at /login")

    if value =~ ~r/^\$\{.+\}$/ do
      info(dim("   it references an env var, so export that variable before serving"))
    end
  end

  defp dashboard_cmd(["password"]) do
    error("usage: mix pepe dashboard password '<password or ${ENV_VAR}>'  (or --clear)")
  end

  defp dashboard_cmd(["hosts", "--clear"]),
    do: clear_dashboard_key("allowed_hosts", "allowed hosts")

  defp dashboard_cmd(["hosts", csv]) when is_binary(csv),
    do: set_dashboard_list("allowed_hosts", csv, "allowed hosts")

  defp dashboard_cmd(["hosts"]),
    do: error("usage: mix pepe dashboard hosts app.example.com,dash.example.com  (or --clear)")

  defp dashboard_cmd(["trusted-proxies", "--clear"]),
    do: clear_dashboard_key("trusted_proxies", "trusted proxies")

  defp dashboard_cmd(["trusted-proxies", csv]) when is_binary(csv),
    do: set_dashboard_list("trusted_proxies", csv, "trusted proxies")

  defp dashboard_cmd(["trusted-proxies"]),
    do: error("usage: mix pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8  (or --clear)")

  defp dashboard_cmd(_), do: dashboard_status()

  defp dashboard_status do
    if Config.dashboard_auth_required?() do
      info("dashboard auth: " <> green("on") <> " - a password is configured; login required")
    else
      info("dashboard auth: off - open to localhost only (remote clients are blocked)")

      info(dim("   enable it: mix pepe dashboard password '<pass>'   (or export PEPE_DASHBOARD_PASSWORD)"))
    end

    info("   allowed hosts  : #{list_or(Config.dashboard_allowed_hosts(), "loopback names only")}")

    info("   trusted proxies: #{list_or(Config.dashboard_trusted_proxies(), "none")}")
    info(dim("   set with: mix pepe dashboard hosts <h1,h2>  |  trusted-proxies <cidr,...>"))
  end

  defp list_or([], default), do: default
  defp list_or(list, _default), do: Enum.join(list, ", ")

  defp set_dashboard_list(key, csv, label) do
    list = csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    put_dashboard(key, list)
    ok("#{label}: #{list_or(list, "(none)")}")
  end

  defp clear_dashboard_key(key, label) do
    cfg = Config.load()
    dash = cfg |> Map.get("dashboard", %{}) |> Map.delete(key)
    Config.save(Map.put(cfg, "dashboard", dash))
    ok("#{label} cleared")
  end

  defp put_dashboard(key, value) do
    cfg = Config.load()
    dash = cfg |> Map.get("dashboard", %{}) |> Map.put(key, value)
    Config.save(Map.put(cfg, "dashboard", dash))
  end

  ###
  ### backup
  ###

  defp backup_help do
    info("""
    mix pepe backup - archive ~/.pepe (config + agent/company workspaces + sessions)

      backup [--output FILE.tgz]    # defaults to pepe-backup-YYYY-MM-DD.tgz

    Also lists the ${ENV_VAR} secrets referenced in your config - they live
    outside the files (never written expanded) and must be saved separately.
    """)
  end

  # Tar up the durable parts of PEPE_HOME (config + agent/company workspaces +
  # sessions), skip the disposable Mnesia cache, then list the ${ENV_VAR} secrets that
  # live outside the files and must be saved separately.
  defp backup_cmd(rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [output: :string])
    home = Config.home()

    if File.dir?(home) do
      run_backup(home, opts[:output])
    else
      error("nothing to back up - #{Config.short_path(home)} doesn't exist yet (run `mix pepe setup`)")
    end
  end

  defp run_backup(home, output) do
    out = Path.expand(output || "pepe-backup-#{Date.utc_today()}.tgz")
    base = Path.basename(home)
    args = ["--exclude", "#{base}/data/mnesia", "-czf", out, "-C", Path.dirname(home), base]

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {_, 0} ->
        ok("backup written to #{green(out)}#{backup_size(out)}")
        info("  included: config.json · agent & company workspaces · shared · sessions")
        info("  skipped:  data/mnesia (disposable cache, rebuilds itself)")
        report_backup_secrets(home)

        info("\nRestore: extract into #{Path.dirname(home)}/ and re-export your secret env vars.")

      {msg, _} ->
        error("backup failed: #{String.trim(msg)}")
    end
  end

  defp backup_size(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} -> " (#{Float.round(bytes / 1024, 1)} KB)"
      _ -> ""
    end
  end

  # Secrets are stored as ${ENV_VAR} references, never raw - so they're NOT in the
  # backup. List them (and whether each is currently set) so they're saved elsewhere.
  defp report_backup_secrets(home) do
    vars =
      case File.read(Path.join(home, "config.json")) do
        {:ok, body} ->
          ~r/\$\{([A-Z0-9_]+)\}/
          |> Regex.scan(body)
          |> Enum.map(&List.last/1)
          |> Enum.uniq()
          |> Enum.sort()

        _ ->
          []
      end

    if vars == [] do
      info("\nNo ${ENV_VAR} secrets referenced - nothing extra to save.")
    else
      puts("\n" <> bold("⚠ Secrets are NOT in the backup - save these env vars separately:"))

      Enum.each(vars, &print_secret_var_line/1)
    end
  end

  defp print_secret_var_line(v) do
    status = if System.get_env(v), do: green("set"), else: red("UNSET")
    puts("  #{v}  (#{status})")
  end

  defp tools do
    info("built-in tools:")

    Enum.each(Pepe.Tools.all(), fn mod ->
      %{"function" => %{"description" => desc}} = mod.spec()
      puts("  #{bold(mod.name())} - #{desc}")
    end)
  end

  # `mix pepe timelearn [AGENT]` - the learning timeline (skills + memory).
  defp timelearn_cmd(args) do
    case List.first(args) || Config.default_agent_name() do
      nil ->
        error("no agent. pass one: mix pepe timelearn AGENT")

      name ->
        c = Pepe.Learning.counts(name)

        info(
          bold("✦ TimeLearn - ") <>
            green(name) <>
            dim("  (#{c[:skill] || 0} skills · #{c[:memory] || 0} memories)")
        )

        case Enum.reverse(Pepe.Learning.timeline(name)) do
          [] -> info(dim("  nothing learned yet."))
          nodes -> Enum.each(nodes, &print_learning_node/1)
        end
    end
  end

  defp print_learning_node(node) do
    icon = if node.kind == :skill, do: "🧠", else: "📝"
    meta = dim("· #{node.source} · #{learn_date(node.at)}")
    info("\n#{icon} #{bold(node.title)} #{meta}")
    info(dim("   " <> (node.summary |> String.replace("\n", " ") |> String.slice(0, 96))))
  end

  # `mix pepe learn ...` - active memory maintenance (the agent consolidates its own
  # standing memory/skills), plus scheduling it.
  alias Pepe.Agent.Reflect

  defp learn_cmd(["help"]), do: learn_help()

  defp learn_cmd(["consolidate" | rest]) do
    case List.first(rest) || Config.default_agent_name() do
      nil ->
        error("no agent. pass one: mix pepe learn consolidate AGENT")

      name ->
        info(dim("Consolidating #{name}'s memory..."))

        case Pepe.Agent.consolidate(name) do
          {:ok, summary, _} -> ok("done. #{String.slice(to_string(summary), 0, 200)}")
          {:error, reason} -> error("consolidation failed: #{inspect(reason)}")
        end
    end
  end

  defp learn_cmd(["auto", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [at: :string, off: :boolean])

    if opts[:off] do
      Reflect.unschedule_auto(name)
      ok("scheduled consolidation off for #{green(name)}")
    else
      {:ok, cron} = Reflect.schedule_auto(name, schedule: opts[:at])
      ok("scheduled consolidation on for #{green(name)} at #{bold(cron.schedule)} (#{cron.timezone})")
    end
  end

  defp learn_cmd(["status"]) do
    scheduled = Config.crons() |> Enum.filter(&(&1.kind == "consolidate"))

    if scheduled == [] do
      info(dim("No agent has scheduled consolidation. Turn it on: mix pepe learn auto AGENT"))
    else
      info(bold("scheduled memory consolidation"))
      Enum.each(scheduled, fn c -> info("  #{green(c.agent)}  #{dim("#{c.schedule} · #{c.timezone}")}") end)
    end
  end

  defp learn_cmd([]), do: learn_help()
  defp learn_cmd(_), do: error("usage: mix pepe learn consolidate|auto|status")

  defp learn_help do
    puts("""
    #{bold("mix pepe learn")} - active memory maintenance (the agent tidies its own memory)

      learn consolidate [AGENT]     run a consolidation pass now (dedupe/prune/merge)
      learn auto AGENT [--at CRON]  schedule nightly consolidation (default 0 3 * * *)
      learn auto AGENT --off        stop scheduled consolidation
      learn status                  show which agents consolidate on a schedule

    This complements the per-conversation learning the agent already does (memory and
    skills after a session): consolidation is a standalone pass over everything it has
    saved. See #{bold("mix pepe timelearn")} for what an agent has learned so far.
    """)
  end

  defp learn_date(0), do: "-"
  defp learn_date(ts), do: local_datetime(ts)

  # Format a unix timestamp in the configured timezone (from `mix pepe setup`), not UTC.
  defp local_datetime(ts) when is_integer(ts) do
    with {:ok, utc} <- DateTime.from_unix(ts),
         {:ok, dt} <- DateTime.shift_zone(utc, Pepe.Config.default_timezone()) do
      Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    else
      _ -> "-"
    end
  end

  defp local_datetime(_), do: "-"

  ###
  ### cron (scheduled tasks)
  ###

  defp cron_cmd(["list" | _]) do
    case Config.crons() do
      [] ->
        info(dim("no scheduled tasks. add one: mix pepe cron add ..."))

      crons ->
        info(bold("✦ Scheduled tasks"))
        Enum.each(crons, &print_cron/1)
    end
  end

  defp cron_cmd(["add" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          name: :string,
          agent: :string,
          prompt: :string,
          schedule: :string,
          timezone: :string,
          model: :string,
          deliver: :string,
          overlap: :boolean
        ]
      )

    with {:ok, name} <- require_opt(opts, :name),
         {:ok, prompt} <- require_opt(opts, :prompt),
         {:ok, schedule} <- require_opt(opts, :schedule),
         {:ok, _} <- Pepe.Cron.parse(schedule) do
      agent = opts[:agent] || Config.default_agent_name()

      if is_nil(agent) do
        error("no agent. pass --agent NAME or set a default agent")
      else
        cron = %Pepe.Config.Cron{
          id: cron_id(name),
          name: name,
          agent: agent,
          prompt: prompt,
          schedule: schedule,
          timezone: opts[:timezone] || Config.default_timezone(),
          model: opts[:model],
          deliver: opts[:deliver] || "none",
          enabled: true,
          overlap: opts[:overlap] == true
        }

        Config.put_cron(cron)
        ok("scheduled task #{green(cron.id)} created")
        print_cron(cron)
      end
    else
      {:error, :missing, key} -> error("cron add needs --#{key}")
      {:error, msg} -> error("invalid --schedule: #{msg}")
    end
  end

  defp cron_cmd(["run", id | _]) do
    case Config.get_cron(id) do
      nil ->
        error("unknown task: #{id}")

      cron ->
        info(dim("running #{id}..."))

        case Pepe.Cron.run(cron, :manual) do
          {:ok, output} -> info("\n" <> output)
          {:error, reason} -> error("task failed: #{inspect(reason)}")
        end
    end
  end

  defp cron_cmd([action, id | _]) when action in ["enable", "disable"] do
    on? = action == "enable"

    case Config.get_cron(id) do
      nil ->
        error("unknown task: #{id}")

      cron ->
        Config.put_cron(%{cron | enabled: on?})
        ok("#{green(id)} #{action}d")
    end
  end

  defp cron_cmd(["remove", id | _]) do
    case Config.get_cron(id) do
      nil ->
        error("unknown task: #{id}")

      _ ->
        Config.delete_cron(id)
        Pepe.Cron.Log.delete(id)
        ok("#{green(id)} removed")
    end
  end

  defp cron_cmd(["history", id | _]), do: cron_cmd(["logs", id])

  defp cron_cmd(["logs", id | _]) do
    case Pepe.Cron.Log.tail(id, 20) do
      [] ->
        info(dim("no runs recorded for #{id} yet"))

      entries ->
        info(bold("✦ Runs of ") <> green(id))

        Enum.each(entries, &print_cron_log_line/1)
    end
  end

  defp cron_cmd(_) do
    info("""
    mix pepe cron - scheduled tasks (recurring agent jobs)

      list                                              list all tasks (+ next run)
      add --name N --prompt "..." --schedule "0 8 * * *"
          [--agent A] [--timezone America/Sao_Paulo]
          [--model M] [--deliver telegram:<chat_id>|none]
          [--overlap]                                   create a task
      run ID                                            force a task now (preview)
      enable ID | disable ID
      remove ID
      logs ID                                           recent run history

    Schedule is a standard 5-field cron expression. Timezone is any IANA name
    (default: #{Config.default_timezone()}). Tasks fire only while `serve`/`gateway` runs.

    A task whose previous run is still going is skipped, and the skip is written to its
    run history (`cron logs ID`), because that is how you find out a job takes longer
    than its own schedule allows. It is skipped rather than piled up because a task here
    is an agent turn: it costs a model call, it has side effects, and every run of it
    shares one agent workspace. `--overlap` runs it anyway, where that is what you want.
    """)
  end

  defp print_cron_log_line(e) do
    mark = if e["ok"], do: "✅", else: "⚠️"
    info("\n#{mark} #{dim(learn_date(e["at"]))} #{dim("· " <> e["source"])}")

    info(
      dim(
        "   " <>
          (to_string(e["output"]) |> String.replace("\n", " ") |> String.slice(0, 120))
      )
    )
  end

  defp print_cron(%Pepe.Config.Cron{} = c) do
    next = Pepe.Cron.next_run(c)
    state = if c.enabled, do: green("enabled"), else: dim("disabled")

    info("\n#{bold(c.id)} - #{c.name}  [#{state}]")
    info(dim("   when:    #{c.schedule} (#{c.timezone})"))
    if next, do: info(dim("   next:    #{Calendar.strftime(next, "%Y-%m-%d %H:%M %Z")}"))
    info(dim("   agent:   #{c.agent}#{if c.model, do: " · model #{c.model}", else: ""}"))
    info(dim("   deliver: #{c.deliver}"))
    if c.last_run, do: info(dim("   last:    #{learn_date(c.last_run)}"))
  end

  defp require_opt(opts, key) do
    case opts[key] do
      nil -> {:error, :missing, key}
      val -> {:ok, val}
    end
  end

  # Slugify a name into a unique cron id.
  defp cron_id(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    base = if base == "", do: "task", else: base
    taken = Enum.map(Config.crons(), & &1.id)

    if base in taken do
      2
      |> Stream.iterate(&(&1 + 1))
      |> Enum.find_value(&unique_cron_suffix(&1, base, taken))
    else
      base
    end
  end

  defp unique_cron_suffix(n, base, taken) do
    candidate = "#{base}-#{n}"
    if candidate not in taken, do: candidate
  end

  ###
  ### mcp (Model Context Protocol servers)
  ###

  defp mcp_cmd(["list" | _]) do
    case Config.mcp_servers() do
      m when map_size(m) == 0 ->
        info(dim("no MCP servers. add one: mix pepe mcp add NAME --command npx --args \"...\""))

      servers ->
        info(bold("✦ MCP servers"))

        Enum.each(servers, &print_mcp_server_line/1)
    end
  end

  defp mcp_cmd(["add", name | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [command: :string, args: :string])

    if is_nil(opts[:command]) do
      error("mcp add needs --command (e.g. npx)")
    else
      args = if opts[:args], do: String.split(opts[:args], " ", trim: true), else: []
      Config.put_mcp_server(name, %{"command" => opts[:command], "args" => args, "env" => %{}})
      ok("MCP server #{green(name)} saved")
      info(dim("validate: mix pepe mcp tools #{name}"))
    end
  end

  defp mcp_cmd(["tools", name | _]) do
    case Config.mcp_server(name) do
      nil ->
        error("unknown MCP server: #{name}")

      _ ->
        info(dim("connecting to #{name}..."))
        print_mcp_tools(name)
    end
  end

  defp mcp_cmd(["remove", name | _]) do
    case Config.mcp_server(name) do
      nil ->
        error("unknown MCP server: #{name}")

      _ ->
        Config.delete_mcp_server(name)
        ok("#{green(name)} removed")
    end
  end

  defp mcp_cmd(_) do
    info("""
    mix pepe mcp - external tool servers (Model Context Protocol)

      add NAME --command npx --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
      list                       list configured servers
      tools NAME                 launch it and list its tools (validate)
      remove NAME

    Put tokens as ${ENV_VAR} refs. Grant an agent only the read tools by adding
    names like mcp__NAME__<tool> to its --tools (see: mix pepe agent).
    """)
  end

  defp print_mcp_server_line({name, cfg}) do
    info("\n#{bold(name)}")
    info(dim("   #{cfg["command"]} #{Enum.join(cfg["args"] || [], " ")}"))
  end

  defp print_mcp_tools(name) do
    case Pepe.MCP.tools(name) do
      {:ok, tools} ->
        info(bold("✦ #{name} tools") <> dim(" (grant read ones to an agent)"))
        Enum.each(tools, &print_mcp_tool_line(name, &1))

      {:error, reason} ->
        error("couldn't reach #{name}: #{inspect(reason)}")
    end
  end

  defp print_mcp_tool_line(name, t) do
    info("\n#{bold("mcp__#{name}__#{t["name"]}")}")
    info(dim("   #{String.slice(to_string(t["description"]), 0, 120)}"))
  end

  # `mix pepe review` - the queue of autonomous writes waiting for approval.
  defp review_cmd(["approve", id | _]) do
    case Pepe.Approval.approve(id) do
      {:ok, _} -> ok("approved #{id} - the change was applied")
      {:error, :not_found} -> error("no pending write with id #{id}")
    end
  end

  defp review_cmd(["reject", id | _]) do
    case Pepe.Approval.reject(id) do
      :ok -> ok("rejected #{id} - discarded, nothing was written")
      {:error, :not_found} -> error("no pending write with id #{id}")
    end
  end

  defp review_cmd(_) do
    case Pepe.Approval.list() do
      [] ->
        info(dim("no writes waiting for review."))
        info(dim("(the queue only fills when review is on: mix pepe config set review_writes true)"))

      entries ->
        info(bold("Autonomous writes awaiting review:") <> dim(" approve/reject with `mix pepe review approve|reject ID`\n"))

        Enum.each(entries, fn e ->
          args = get_in(e, ["tool_call", "function", "arguments"]) || ""
          info("#{green(e["id"])}  #{bold(e["tool"])} by #{e["agent"]}")
          info(dim("   " <> String.slice(to_string(args), 0, 160)))
        end)
    end
  end

  # `pepe version` - what is running, and on what. The build target is printed alongside
  # the number because it is the other half of a useful bug report: an "it won't start" is
  # a different problem on pepe_linux_arm than on pepe_macos_x86.
  defp version_cmd do
    info("pepe #{Pepe.Update.current()}")

    if Pepe.Update.running_from_source?() do
      info(dim("running from a source checkout"))
    else
      info(dim(Pepe.Update.target() || "unknown build target"))
    end
  end

  # `mix pepe update` - self-update the packaged binary to the latest release.
  defp update_cmd do
    info(dim("checking for a newer release..."))

    case Pepe.Update.run() do
      {:ok, :updated, v} ->
        ok("updated to v#{v}  (previous binary kept as pepe.old) - restart pepe to run it")

      {:ok, :up_to_date, v} ->
        ok("already on the latest version (v#{v})")

      {:error, :from_source} ->
        info(yellow("you're running from a source checkout, not the binary - update with `git pull`"))

      {:error, :unsupported_platform} ->
        error("no prebuilt binary for this platform - build from source or use `mix pepe`")

      {:error, reason} ->
        error("update failed: #{describe(reason)}")
    end
  end

  # `mix pepe doctor [--offline]` - health-check the setup (live probes by default).
  defp doctor_cmd(rest) do
    live? = "--offline" not in rest
    info(bold("✦ Pepe doctor") <> dim(if live?, do: " (live probes)", else: " (offline)"))

    # `checks/1` always returns at least the ones that need no config, so there is no
    # empty case to write a branch for: it would be dead code, and Dialyzer says so.
    checks = Pepe.Doctor.checks(live: live?)

    Enum.each(checks, fn
      {area, subject, :ok} -> info("#{green("✓")} [#{area}] #{subject}")
      {area, subject, {:warn, msg}} -> info("#{dim("⚠")} [#{area}] #{subject} - #{msg}")
      {area, subject, {:error, msg}} -> error("[#{area}] #{subject} - #{msg}")
    end)

    if Pepe.Doctor.healthy?(checks) do
      ok("healthy")
    else
      error("issues found - fix the ✗ items above")
    end
  end

  defp help do
    puts(@moduledoc |> String.replace(~r/^## /m, ""))
  end

  ###
  ### output helpers
  ###

  # The escript/release entry point (Pepe.CLI) sets this - there's no `mix`
  # there, so usage/help text (written once, for `mix pepe ...`) should read
  # as `pepe ...` instead. Every stdout call in this module goes through
  # `puts/1` so this applies uniformly, not just to the top-level help text.
  defp cli_text(msg) do
    if Process.get(:pepe_cli_standalone, false), do: String.replace(msg, "mix pepe", "pepe"), else: msg
  end

  defp puts(msg), do: IO.puts(cli_text(msg))

  defp ok(msg), do: puts(green("✓ ") <> msg)
  defp info(msg), do: puts(msg)
  defp error(msg), do: IO.puts(:stderr, red("✗ ") <> cli_text(msg))

  defp green(s), do: IO.ANSI.green() <> s <> IO.ANSI.reset()
  defp red(s), do: IO.ANSI.red() <> s <> IO.ANSI.reset()
  defp yellow(s), do: IO.ANSI.yellow() <> s <> IO.ANSI.reset()
  defp bold(s), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
