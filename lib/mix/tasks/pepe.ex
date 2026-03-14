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

  Bearer tokens for the `/v1` HTTP API. With no tokens the API is open (legacy
  behaviour); creating the first one locks it - every call then needs a valid token.
  Scope a token to a company (`--company`) or a single agent (`--agent HANDLE`).

      mix pepe token add [--company CO] [--agent HANDLE] [--label "..."]
      mix pepe token list
      mix pepe token revoke ID

  ## Watches (one-shot "notify me when X")

  A watch polls a cheap probe and notifies **once** when it passes, then stops -
  durable across restarts. Agent-judged watches are created from chat (the `watch`
  tool); the CLI creates probe watches.

      mix pepe watch add "site up" --probe "curl -sf https://x" [--message "..."] [--every 120] [--deliver telegram:<chat>]
      mix pepe watch list
      mix pepe watch pause ID | resume ID | cancel ID

  ## Agents

      mix pepe agent add NAME --model MODEL --prompt "..." --tools bash,read_file [--can-message b,c] [--can-manage x,y|*|none] [--default] [--company CO]
      mix pepe agent list [--company CO | --all]
      mix pepe agent route FROM TO [--remove] [--company CO]   # let FROM message TO (directed)
      mix pepe agent manage ADMIN TARGET [--remove]  # let ADMIN administer TARGET ("*" = all)
      mix pepe agent rename OLD NEW          # rename + move its workspace dir
      mix pepe agent remove NAME
      mix pepe agent default NAME

  ## Running

      mix pepe run [AGENT] "your prompt"      # one-shot, streams to stdout
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
      mix pepe cron list|add|run|logs ...        # scheduled tasks (recurring agent jobs)
      mix pepe usage [--company CO] ...          # token usage & cost by cycle (billing)
      mix pepe usage export --company CO ...     # generate a client invoice (md/csv)
      mix pepe usage prices [--refresh]        # show/refresh the live model price cache
      mix pepe mcp add|list|tools|remove ...      # external tool servers (MCP: Sentry, GitHub, ...)
      mix pepe doctor [--offline]              # health-check the whole setup
      mix pepe setup                           # scaffold ~/.pepe/config.json
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
    dispatch(argv)
  end

  @doc """
  Dispatch a parsed `argv` to the matching command. Shared by the `mix pepe`
  task and the standalone `pepe` escript (`Pepe.CLI`), so both entry points
  behave identically. The escript calls this directly (no Mix at runtime).
  """
  def dispatch(argv) do
    case argv do
      [] ->
        help()

      ["help"] ->
        help()

      # `pepe help <group>` mirrors `pepe <group> help`.
      ["help", "agent" | _] ->
        agent_cmd(["help"])

      ["help", "model" | _] ->
        model_cmd(["help"])

      ["help", "gateway" | _] ->
        gateway_cmd(["help"])

      ["help", "company" | _] ->
        company_cmd(["help"])

      ["setup" | _] ->
        with_config(&setup/0)

      ["config" | rest] ->
        with_config(fn -> config_cmd(rest) end)

      ["dashboard" | rest] ->
        with_config(fn -> dashboard_cmd(rest) end)

      ["backup" | rest] ->
        with_config(fn -> backup_cmd(rest) end)

      ["tools" | _] ->
        with_config(&tools/0)

      ["timelearn" | rest] ->
        with_config(fn -> timelearn_cmd(rest) end)

      # `cron list/history` only read files; `cron run` needs the full app to call
      # the model, so route everything through with_app.
      ["cron", sub | rest] when sub in ["list", "history", "logs"] ->
        with_config(fn -> cron_cmd([sub | rest]) end)

      ["cron" | rest] ->
        with_app([], fn -> cron_cmd(rest) end)

      ["doctor" | rest] ->
        with_app([], fn -> doctor_cmd(rest) end)

      # `mcp tools` launches the server (needs the app); the rest just edit config.
      ["mcp", "tools" | rest] ->
        with_app([], fn -> mcp_cmd(["tools" | rest]) end)

      ["mcp" | rest] ->
        with_config(fn -> mcp_cmd(rest) end)

      # `usage prices --refresh` fetches over the network (needs Req/the app);
      # reporting just reads the ledger files.
      ["usage", "prices" | rest] ->
        with_app([], fn -> usage_cmd(["prices" | rest]) end)

      ["usage" | rest] ->
        with_config(fn -> usage_cmd(rest) end)

      ["company" | rest] ->
        with_config(fn -> company_cmd(rest) end)

      # `hooks generate` calls a model (needs the app); `list` just reads.
      ["hooks", "generate" | rest] ->
        with_app([], fn -> hooks_cmd(["generate" | rest]) end)

      ["hooks" | rest] ->
        with_config(fn -> hooks_cmd(rest) end)

      ["token" | rest] ->
        with_config(fn -> token_cmd(rest) end)

      ["watch" | rest] ->
        with_config(fn -> watch_cmd(rest) end)

      ["model" | rest] ->
        with_config(fn -> model_cmd(rest) end)

      ["agent" | rest] ->
        with_config(fn -> agent_cmd(rest) end)

      ["run" | rest] ->
        with_app([], fn -> run_cmd(rest) end)

      ["chat" | rest] ->
        with_app([persist: true], fn -> tui_cmd(rest) end)

      ["tui" | rest] ->
        with_app([persist: true], fn -> tui_cmd(rest) end)

      ["serve" | rest] ->
        with_app([serve: true, gateways: true, port: serve_port(rest)], fn -> serve_cmd(rest) end)

      # Configuring a gateway only touches the config file - no app needed.
      ["gateway", "telegram", "setup" | _] ->
        with_config(&telegram_setup/0)

      ["gateway", "telegram", sub | rest] when sub in ["add", "remove", "list"] ->
        with_config(fn -> gateway_cmd(["telegram", sub | rest]) end)

      # WhatsApp connections are webhook-based - served by `mix pepe serve`, so the
      # CLI just edits config (no running poller).
      ["gateway", "whatsapp" | rest] ->
        with_config(fn -> gateway_cmd(["whatsapp" | rest]) end)

      ["gateway" | rest] ->
        with_app([gateways: true], fn -> gateway_cmd(rest) end)

      other ->
        error("unknown command: #{Enum.join(other, " ")}\n") && help()
    end
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

  defp model_cmd(["add", name | rest]) do
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

    if validate_scope(name, opts[:company]) == :ok do
      handle = Company.handle(opts[:company], name)

      # Guided flow: no --base-url ⇒ pick a provider from the catalog, resolve its
      # URL + API key, then pick a model. --base-url ⇒ use it directly.
      {base_url, api_key, oauth} =
        if opts[:base_url] do
          {opts[:base_url], opts[:api_key], nil}
        else
          choose_provider()
        end

      cond do
        is_nil(base_url) ->
          error("no provider selected; aborting.")

        true ->
          model_id = opts[:model] || pick_model(base_url, api_key)

          case model_id do
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
              if opts[:default], do: Config.set_default_model_for(opts[:company], name)
              ok("model connection #{green(handle)} saved -> #{model.base_url} (#{green(id)})")
          end
      end
    end
  end

  defp model_cmd(["providers" | _]) do
    info("known providers (pick one with `mix pepe model add NAME`):")

    Pepe.Providers.all()
    |> Enum.each(fn p ->
      key = p.env || "no key"
      IO.puts("  #{bold(p.label)}\n    base-url: #{p.base_url || "(custom)"}  ·  key: #{key}")
    end)
  end

  defp model_cmd(["models" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [base_url: :string, api_key: :string])
    base_url = opts[:base_url] || "https://api.openai.com/v1"

    case fetch_models(base_url, opts[:api_key]) do
      {:ok, ids} ->
        info("#{length(ids)} models at #{base_url}:")
        Enum.each(ids, &IO.puts("  #{&1}"))

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
        info(
          "no model connections. add one:\n  mix pepe model add openrouter --base-url https://openrouter.ai/api/v1 --api-key '${OPENROUTER_API_KEY}' --model anthropic/claude-3.5-sonnet"
        )

      models ->
        Enum.each(models, fn m ->
          mark = if m.name == default, do: " #{green("(default)")}", else: ""

          IO.puts(
            "#{bold(m.name)}#{mark}\n  url:   #{m.base_url}\n  model: #{m.model}\n  api:   #{m.api}"
          )
        end)
    end
  end

  defp model_cmd(["remove", name | _]) do
    Config.delete_model(name)
    ok("removed model connection #{name}")
  end

  defp model_cmd(["default", name | _]) do
    Config.set_default_model(name)
    ok("default model -> #{name}")
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

        case Pepe.LLM.chat(model, [%{"role" => "user", "content" => "ping"}], max_tokens: 5) do
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
      remove NAME
      default NAME                           set the default model
    """)
  end

  defp model_cmd(_),
    do: error("usage: mix pepe model [add|list|models|providers|test|remove|default] (or: help)")

  defp add_model_interactively do
    name =
      Owl.IO.input(label: "Name for this connection:")
      |> ensure_unique(model_names(), "model connection")

    model_cmd(["add", name, "--default"])
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
      info(
        dim("note: api key #{api_key} resolves to empty - export the env var, or this may 401")
      )
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
    ids =
      if length(ids) > 20 do
        case Owl.IO.input(label: "Filter models (substring, blank for all):", optional: true) do
          blank when blank in [nil, ""] ->
            ids

          filter ->
            down = String.downcase(filter)

            case Enum.filter(ids, &String.contains?(String.downcase(&1), down)) do
              [] -> ids
              filtered -> filtered
            end
        end
      else
        ids
      end

    Pepe.TUI.select(ids, label: bold("Select the default model:"))
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
        date = at |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
        info("#{c} live prices cached · refreshed #{date}")
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
            IO.puts(body)

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
    IO.puts("#{bold("usage")} · #{label} · by #{s.granularity} · #{s.currency}\n")

    if s.buckets == [] do
      info("no usage recorded yet for this scope.")
    else
      Enum.each(s.buckets, fn b ->
        IO.puts(
          "  #{String.pad_trailing(b.key, 18)} " <>
            "#{String.pad_leading(fmt_tok(b.total), 10)} tok  " <>
            "cost #{String.pad_leading(fmt_money(b.cost, s.currency), 12)}  " <>
            "bill #{String.pad_leading(fmt_money(b.billable, s.currency), 12)}"
        )
      end)

      t = s.totals

      IO.puts(
        "\n  #{bold(String.pad_trailing("TOTAL", 18))} " <>
          "#{String.pad_leading(fmt_tok(t.total), 10)} tok  " <>
          "cost #{String.pad_leading(fmt_money(t.cost, s.currency), 12)}  " <>
          "bill #{String.pad_leading(fmt_money(t.billable, s.currency), 12)}"
      )
    end

    if scope == :all and s.by_company != [] do
      IO.puts("\n#{bold("by company")}")

      Enum.each(s.by_company, fn c ->
        markup = if c.markup != 1.0, do: " (×#{c.markup})", else: ""

        IO.puts(
          "  #{String.pad_trailing(c.key, 16)} " <>
            "cost #{String.pad_leading(fmt_money(c.cost, s.currency), 12)}  " <>
            "bill #{String.pad_leading(fmt_money(c.billable, s.currency), 12)}#{markup}"
        )
      end)
    end
  end

  defp fmt_tok(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_tok(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_tok(n), do: Integer.to_string(n)

  defp fmt_money(amount, currency),
    do: "#{currency} #{:erlang.float_to_binary(amount / 1, decimals: 2)}"

  defp usage_help do
    IO.puts("""
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

    cond do
      is_nil(model) ->
        error("no model to generate with - pass --model NAME (or set a default model)")

      true ->
        info("asking #{model} to build a pii_redact config...")

        case Pepe.Hooks.Generator.generate(desc, model) do
          {:ok, config, dropped} ->
            IO.puts(Jason.encode!(config, pretty: true))
            if dropped != [], do: info(dim("dropped (invalid): #{Enum.join(dropped, ", ")}"))

            if opts[:save] do
              Config.put_hook_settings("pii_redact", config)
              ok("saved to hooks.pii_redact")
            else
              info(dim("re-run with --save to store it, or paste it under \"hooks\" yourself"))
            end

          {:error, reason} ->
            error("couldn't generate: #{inspect(reason)}")
        end
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

  defp company_cmd(["list" | _]) do
    case Config.companies() do
      [] ->
        info(
          "no companies. everything runs in the root scope. add one:\n  mix pepe company add acme"
        )

      companies ->
        Enum.each(companies, fn name ->
          count = length(Config.agents_in(name))
          desc = (Config.get_company(name) || %{})["description"]
          suffix = if desc, do: " - #{desc}", else: ""
          IO.puts("#{bold(name)} (#{count} agent#{if count == 1, do: "", else: "s"})#{suffix}")
        end)
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
    IO.puts("""
    #{bold("mix pepe company")} - multi-tenant scopes

      add NAME [--description "..."]   create a company (an isolated tenant)
      list                            list companies + how many agents each has
      rename OLD NEW                  rename a company (re-keys all its agents & bindings)
      remove NAME [--force]           delete a company (--force also drops its agents)

    Without --company, every command uses the root scope (the single-tenant default).
    Add --company NAME to an agent/model command to act inside that company; its
    agents, workspaces, shared/ space and models are isolated from other companies.
    """)
  end

  defp company_cmd(other),
    do: error("unknown company command: #{Enum.join(other, " ")} (try: mix pepe company help)")

  ###
  ### API token commands
  ###

  defp token_cmd(["add" | rest]) do
    {opts, _} =
      OptionParser.parse!(rest, strict: [company: :string, agent: :string, label: :string])

    attrs = [company: opts[:company], agent: opts[:agent], label: opts[:label]]

    case Config.add_api_token(attrs) do
      {:ok, raw, id} ->
        scope =
          cond do
            opts[:agent] -> "agent #{opts[:agent]}"
            opts[:company] -> "company #{opts[:company]}"
            true -> "root"
          end

        ok("API token created (id #{green(id)}, scope: #{scope})")
        IO.puts("\n  #{bold(raw)}\n")
        info("Save it now - it is shown only once and stored only as a hash.")

      {:error, :unknown_company} ->
        error("unknown company: #{opts[:company]}")

      {:error, :unknown_agent} ->
        error("unknown agent: #{opts[:agent]}")

      {:error, :agent_out_of_scope} ->
        error("agent #{opts[:agent]} is not in company #{opts[:company] || "(root)"}")
    end
  end

  defp token_cmd(["list" | _]) do
    case Config.api_tokens() do
      [] ->
        info("no API tokens - the /v1 API is open. lock it with: mix pepe token add")

      tokens ->
        Enum.each(tokens, fn t ->
          scope = t["agent"] || t["company"] || "root"
          label = if t["label"], do: " - #{t["label"]}", else: ""
          IO.puts("#{bold(t["id"])}  #{t["prefix"]}  [#{scope}]#{label}")
        end)
    end
  end

  defp token_cmd(["revoke", id | _]) do
    case Config.revoke_api_token(id) do
      :ok -> ok("revoked token #{id}")
      {:error, :not_found} -> error("unknown token id: #{id}")
    end
  end

  defp token_cmd(_) do
    IO.puts("""
    #{bold("mix pepe token")} - API access tokens for /v1

      add [--company CO] [--agent HANDLE] [--label "..."]   mint a token (shown once)
      list                                                  list tokens (scope + fingerprint)
      revoke ID                                             revoke a token

    No tokens ⇒ the /v1 API is open. The first token locks it: every call then needs
    `Authorization: Bearer ctx_...`. A token scoped to a company reaches only its
    agents; scoped to an agent, only that one.
    """)
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
        error(
          "watch add needs --probe \"<command>\" (agent-checked watches are created from chat)"
        )

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

        ok(
          "watch #{green(watch.id)} created (probe every #{watch.interval_s}s -> #{watch.origin["channel"]})"
        )
    end
  end

  defp watch_cmd(["list" | _]) do
    case Config.watches() do
      [] ->
        info(
          "no watches. create one from chat, or: mix pepe watch add \"site up\" --probe \"curl -sf https://x\""
        )

      watches ->
        Enum.each(watches, fn w ->
          detail = w.trigger["command"] || w.trigger["prompt"] || ""

          IO.puts(
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
    IO.puts("""
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

    if base not in taken,
      do: base,
      else: base <> "-" <> Integer.to_string(System.unique_integer([:positive]))
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
          default: :boolean
        ]
      )

    if validate_scope(name, opts[:company]) == :ok do
      handle = Company.handle(opts[:company], name)

      tools =
        case opts[:tools] do
          nil -> Pepe.Tools.names()
          "" -> []
          str -> str |> String.split(",") |> Enum.map(&String.trim/1)
        end

      # Routes are scoped: a bare peer name resolves into this agent's own company.
      can_message =
        case opts[:can_message] do
          v when v in [nil, ""] -> []
          str -> str |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> qualify(handle)))
        end

      # --can-manage: omitted -> nil (itself only); "none" -> [] (nobody); "*" or a
      # comma list -> those. Mirrors Pepe.Config.can_manage?/2.
      can_manage =
        case opts[:can_manage] do
          nil -> nil
          "none" -> []
          "*" -> ["*"]
          str -> str |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> qualify(handle)))
        end

      hooks =
        case opts[:hooks] do
          v when v in [nil, ""] -> []
          str -> str |> String.split(",") |> Enum.map(&String.trim/1)
        end

      agent = %Agent{
        name: handle,
        description: opts[:description],
        model: opts[:model],
        system_prompt: opts[:prompt] || "You are Pepe, a helpful AI agent.",
        tools: tools,
        can_message: can_message,
        can_manage: can_manage,
        hooks: hooks,
        max_iterations: opts[:max_iterations] || 12,
        temperature: opts[:temperature]
      }

      Config.put_agent(agent)
      if opts[:default], do: Config.set_default_agent_for(opts[:company], name)
      ok("agent #{green(handle)} saved (tools: #{Enum.join(tools, ", ")})")
    end
  end

  defp agent_cmd(["list" | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string, all: :boolean])
    default = Config.default_agent_name()

    agents =
      cond do
        opts[:all] -> Config.agents()
        true -> Config.agents_in(opts[:company])
      end

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
        Enum.each(agents, fn a ->
          mark = if a.name == default, do: " #{green("(default)")}", else: ""

          routes =
            if a.can_message == [], do: "", else: "\n  -> #{Enum.join(a.can_message, ", ")}"

          manages = manages_line(a.can_manage)

          IO.puts(
            "#{bold(a.name)}#{mark}\n  model: #{a.model || "(default)"}\n  tools: #{Enum.join(a.tools, ", ")}#{routes}#{manages}"
          )
        end)
    end
  end

  defp agent_cmd(["remove", name | rest]) do
    {opts, _} = OptionParser.parse!(rest, strict: [company: :string])
    handle = Company.handle(opts[:company], name)
    Config.delete_agent(handle)
    ok("removed agent #{handle}")
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
    Config.set_default_agent_for(opts[:company], name)
    scope = if opts[:company], do: " for #{opts[:company]}", else: ""
    ok("default agent#{scope} -> #{name}")
  end

  defp agent_cmd(cmd) when cmd in [[], ["help"]] do
    info("""
    mix pepe agent - manage agents

      add NAME [--model M] [--prompt "..."] [--tools t1,t2]
               [--can-message b,c] [--can-manage x,y|*|none] [--default] [--company CO]
      list [--company CO | --all]                          list agents (+ routes)
      route FROM TO [--remove] [--company CO]              directed A->B messaging
      manage ADMIN TARGET [--remove] [--company CO]        let ADMIN administer TARGET (or "*")
      rename OLD NEW                                        rename + move its dir
      remove NAME [--company CO]
      default NAME [--company CO]                           set the (scope) default agent

    Capabilities are controlled by an agent's --tools (a capability = having its
    tool); learning is controlled per-conversation by a bot's `trainers` list.
    Add --company CO to scope any of these to a company; without it, the root scope.
    """)
  end

  defp agent_cmd(other),
    do: error("unknown: mix pepe agent #{Enum.join(other, " ")}  (try: mix pepe agent help)")

  # Only surface management scope when it's beyond the default (itself only).
  defp manages_line(nil), do: ""
  defp manages_line([]), do: "\n  ⚙ manages: nobody"
  defp manages_line(["*"]), do: "\n  ⚙ manages: all agents"
  defp manages_line(list) when is_list(list), do: "\n  ⚙ manages: #{Enum.join(list, ", ")}"

  ###
  ### run / chat
  ###

  defp run_cmd([]), do: error("usage: mix pepe run [AGENT] \"prompt\"")

  defp run_cmd(args) do
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
      {:ok, _content, _msgs} -> IO.puts("")
      {:error, reason} -> error("\n#{inspect(reason)}")
    end
  end

  # The interactive console gateway lives in Pepe.Gateways.TUI; just resolve the
  # agent and hand off. `chat` and `tui` both land here.
  defp tui_cmd(args) do
    # Accept the agent as a positional (`tui NAME`) or a flag (`tui --agent NAME`),
    # and an optional `--session KEY` to resume/separate console sessions.
    {opts, rest} =
      OptionParser.parse!(args, strict: [agent: :string, session: :string, company: :string])

    raw = opts[:agent] || List.first(rest)

    agent_name =
      cond do
        raw && opts[:company] -> Company.handle(opts[:company], raw)
        raw -> raw
        opts[:company] -> Config.default_agent_for(opts[:company])
        true -> Config.default_agent_name()
      end

    case agent_name && Config.get_agent(agent_name) do
      nil ->
        error(
          "no agent. create one with `mix pepe agent add ...` or pass one: mix pepe tui [--agent NAME]"
        )

      agent ->
        Pepe.Gateways.TUI.start(agent.name, opts[:session])
    end
  end

  ###
  ### serve / gateway
  ###

  defp serve_cmd(_rest) do
    port = PepeWeb.Endpoint.config(:http)[:port] || 4000

    ok("Pepe serving on http://localhost:#{port}  (override with PORT=NNNN)")

    info("""
      OpenAI API : POST http://localhost:#{port}/v1/chat/completions
      Models     : GET  http://localhost:#{port}/v1/models
      Health     : GET  http://localhost:#{port}/health
      WebSocket  : ws://localhost:#{port}/socket/websocket  (topic agent:default)
    """)

    dashboard_posture()
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
        info(
          dim(
            "   dashboard: open on localhost only; remote clients are blocked until you set a password"
          )
        )

      true ->
        info("")
        info(yellow("   dashboard: bound to a public interface with NO password."))
        info(yellow("   Remote access is blocked (fail-closed). To allow it:"))

        info(
          yellow(
            "     mix pepe dashboard password '<pass>'   (or bind to 127.0.0.1 and tunnel in)"
          )
        )
    end
  end

  defp gateway_cmd(["whatsapp", "list" | _]) do
    case Config.webhooks() |> Enum.filter(fn {_s, e} -> e["provider"] == "whatsapp" end) do
      [] ->
        info(
          "no WhatsApp connections. Add one:\n  mix pepe gateway whatsapp add support --agent <handle>"
        )

      conns ->
        Enum.each(conns, fn {slug, e} ->
          co = e["company"] || "root"
          IO.puts("#{bold(slug)} [#{e["mode"] || "support"}] -> #{e["agent"] || "(default)"}")
          IO.puts(dim("   #{webhook_host()}/webhooks/#{co}/whatsapp/#{slug}"))
        end)
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
        # support defaults: never learn + ephemeral; admin: learns + persisted.
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
  end

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

        Enum.each(bots, fn b ->
          state =
            if Pepe.Gateways.Telegram.bot_active?(b), do: green("active"), else: dim("inactive")

          info("\n#{bold(b["name"])}  [#{state}]")
          info(dim("   agent:    #{b["agent"] || "(default)"}"))
          info(dim("   token:    #{token_hint(b["bot_token"])}"))
          info(dim("   learns from: #{trainers_hint(b["trainers"])}"))
        end)
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
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Integer.parse/1)
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
    Config.load() |> Config.save()

    if configured?(), do: config_menu(), else: first_run_setup()
  end

  defp configured?, do: Config.models() != [] or Config.agents() != []

  # Subsequent runs: pick what to add/reconfigure instead of redoing every step.
  defp config_menu do
    info(bold("Pepe setup") <> dim(" - you're already configured. What do you want to do?\n"))

    options = [
      {:model, "Model connection - add or switch the default"},
      {:agent, "Agent - add or set the default"},
      {:telegram, "Telegram gateway"},
      {:language, "Language for system messages"},
      {:timezone, "Default timezone for scheduled tasks"},
      {:full, "Run the full guided setup"},
      {:done, "Done"}
    ]

    {action, _label} =
      Pepe.TUI.select(options,
        label: bold("Configure:"),
        render_as: fn {_a, label} -> label end
      )

    case action do
      :done ->
        ok("Done.")

      :full ->
        first_run_setup()

      :model ->
        model_cmd([])
        config_menu()

      :agent ->
        add_agent()
        config_menu()

      :telegram ->
        telegram_setup()
        config_menu()

      :language ->
        setup_language()
        config_menu()

      :timezone ->
        setup_timezone()
        config_menu()
    end
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
            info("\n" <> green("✓ All set!") <> "  Try:  " <> bold("pepe run \"hello\""))
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
    ok("language -> #{code}")
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
    info("models: #{Config.models() |> Enum.map(& &1.name) |> Enum.join(", ")}")
    info("agents: #{Config.agents() |> Enum.map(& &1.name) |> Enum.join(", ")}")
  end

  ###
  ### dashboard (auth)
  ###

  defp dashboard_cmd(["password", "--clear"]) do
    cfg = Config.load()
    dash = cfg |> Map.get("dashboard", %{}) |> Map.delete("password")
    Config.save(Map.put(cfg, "dashboard", dash))

    if System.get_env("PEPE_DASHBOARD_PASSWORD") do
      ok(
        "cleared the config password (but PEPE_DASHBOARD_PASSWORD is still set in the environment)"
      )
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

      info(
        dim(
          "   enable it: mix pepe dashboard password '<pass>'   (or export PEPE_DASHBOARD_PASSWORD)"
        )
      )
    end

    info(
      "   allowed hosts  : #{list_or(Config.dashboard_allowed_hosts(), "loopback names only")}"
    )

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

  # Tar up the durable parts of PEPE_HOME (config + agent/company workspaces +
  # sessions), skip the disposable Mnesia cache, then list the ${ENV_VAR} secrets that
  # live outside the files and must be saved separately.
  defp backup_cmd(rest) do
    {opts, _} = OptionParser.parse!(rest, strict: [output: :string])
    home = Config.home()

    cond do
      not File.dir?(home) ->
        error("nothing to back up - #{home} doesn't exist yet (run `mix pepe setup`)")

      true ->
        out = Path.expand(opts[:output] || "pepe-backup-#{Date.utc_today()}.tgz")
        base = Path.basename(home)
        args = ["--exclude", "#{base}/data/mnesia", "-czf", out, "-C", Path.dirname(home), base]

        case System.cmd("tar", args, stderr_to_stdout: true) do
          {_, 0} ->
            ok("backup written to #{green(out)}#{backup_size(out)}")
            info("  included: config.json · agent & company workspaces · shared · sessions")
            info("  skipped:  data/mnesia (disposable cache, rebuilds itself)")
            report_backup_secrets(home)

            info(
              "\nRestore: extract into #{Path.dirname(home)}/ and re-export your secret env vars."
            )

          {msg, _} ->
            error("backup failed: #{String.trim(msg)}")
        end
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
      IO.puts("\n" <> bold("⚠ Secrets are NOT in the backup - save these env vars separately:"))

      Enum.each(vars, fn v ->
        status = if System.get_env(v), do: green("set"), else: red("UNSET")
        IO.puts("  #{v}  (#{status})")
      end)
    end
  end

  defp tools do
    info("built-in tools:")

    Enum.each(Pepe.Tools.all(), fn mod ->
      %{"function" => %{"description" => desc}} = mod.spec()
      IO.puts("  #{bold(mod.name())} - #{desc}")
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

  defp learn_date(0), do: "-"

  defp learn_date(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "-"
    end
  end

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
          deliver: :string
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
          enabled: true
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

        Enum.each(entries, fn e ->
          mark = if e["ok"], do: "✅", else: "⚠️"
          info("\n#{mark} #{dim(learn_date(e["at"]))} #{dim("· " <> e["source"])}")

          info(
            dim(
              "   " <>
                (to_string(e["output"]) |> String.replace("\n", " ") |> String.slice(0, 120))
            )
          )
        end)
    end
  end

  defp cron_cmd(_) do
    info("""
    mix pepe cron - scheduled tasks (recurring agent jobs)

      list                                              list all tasks (+ next run)
      add --name N --prompt "..." --schedule "0 8 * * *"
          [--agent A] [--timezone America/Sao_Paulo]
          [--model M] [--deliver telegram:<chat_id>|none]   create a task
      run ID                                            force a task now (preview)
      enable ID | disable ID
      remove ID
      logs ID                                           recent run history

    Schedule is a standard 5-field cron expression. Timezone is any IANA name
    (default: #{Config.default_timezone()}). Tasks fire only while `serve`/`gateway` runs.
    """)
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

    if base not in taken do
      base
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n -> if "#{base}-#{n}" not in taken, do: "#{base}-#{n}" end)
    end
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

        Enum.each(servers, fn {name, cfg} ->
          info("\n#{bold(name)}")
          info(dim("   #{cfg["command"]} #{Enum.join(cfg["args"] || [], " ")}"))
        end)
    end
  end

  defp mcp_cmd(["add", name | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [command: :string, args: :string])

    cond do
      is_nil(opts[:command]) ->
        error("mcp add needs --command (e.g. npx)")

      true ->
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

        case Pepe.MCP.tools(name) do
          {:ok, tools} ->
            info(bold("✦ #{name} tools") <> dim(" (grant read ones to an agent)"))

            Enum.each(tools, fn t ->
              info("\n#{bold("mcp__#{name}__#{t["name"]}")}")
              info(dim("   #{String.slice(to_string(t["description"]), 0, 120)}"))
            end)

          {:error, reason} ->
            error("couldn't reach #{name}: #{inspect(reason)}")
        end
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

  # `mix pepe doctor [--offline]` - health-check the setup (live probes by default).
  defp doctor_cmd(rest) do
    live? = "--offline" not in rest
    info(bold("✦ Pepe doctor") <> dim(if live?, do: " (live probes)", else: " (offline)"))

    checks = Pepe.Doctor.checks(live: live?)

    if checks == [] do
      info(dim("nothing configured to check yet."))
    else
      Enum.each(checks, fn
        {area, subject, :ok} -> info("#{green("✓")} [#{area}] #{subject}")
        {area, subject, {:warn, msg}} -> info("#{dim("⚠")} [#{area}] #{subject} - #{msg}")
        {area, subject, {:error, msg}} -> error("✗ [#{area}] #{subject} - #{msg}")
      end)

      if Pepe.Doctor.healthy?(checks) do
        ok("healthy")
      else
        error("issues found - fix the ✗ items above")
      end
    end
  end

  defp help do
    IO.puts(@moduledoc |> String.replace(~r/^## /m, ""))
  end

  ###
  ### output helpers
  ###

  defp ok(msg), do: IO.puts(green("✓ ") <> msg)
  defp info(msg), do: IO.puts(msg)
  defp error(msg), do: IO.puts(:stderr, red("✗ ") <> msg)

  defp green(s), do: IO.ANSI.green() <> s <> IO.ANSI.reset()
  defp red(s), do: IO.ANSI.red() <> s <> IO.ANSI.reset()
  defp yellow(s), do: IO.ANSI.yellow() <> s <> IO.ANSI.reset()
  defp bold(s), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
