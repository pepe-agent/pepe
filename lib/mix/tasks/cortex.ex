defmodule Mix.Tasks.Cortex do
  @shortdoc "Cortex CLI — manage agents & model connections, run, chat, serve"
  @moduledoc """
  Cortex command-line interface.

  Create model connections, define agents, run one-shot prompts, chat
  interactively, expose the OpenAI-compatible HTTP API + WebSocket, and run the
  Telegram gateway.

  ## Model connections

      mix cortex model                                        # show current + switch/add (easiest)

      # guided: pick a provider → auth method → model
      mix cortex model add NAME [--default]
      # or fully manual:
      mix cortex model add NAME --base-url URL --api-key KEY [--model ID] [--default]

      mix cortex model providers                              # list known providers
      mix cortex model models --base-url URL --api-key KEY    # list a provider's models
      mix cortex model list                                   # list saved connections
      mix cortex model test [NAME]                            # ping a connection to verify it works
      mix cortex model remove NAME
      mix cortex model default NAME

  ## Agents

      mix cortex agent add NAME --model MODEL --prompt "..." --tools bash,read_file [--default]
      mix cortex agent list
      mix cortex agent rename OLD NEW          # rename + move its workspace dir
      mix cortex agent remove NAME
      mix cortex agent default NAME

  ## Running

      mix cortex run [AGENT] "your prompt"      # one-shot, streams to stdout
      mix cortex tui [AGENT | --agent NAME] [--session KEY]   # interactive console, keeps the session (alias: chat)
      mix cortex serve [--port 4000]             # OpenAI API + WebSocket server
      mix cortex gateway telegram setup          # configure the Telegram bot token
      mix cortex gateway telegram                # run the Telegram gateway

  ## Misc

      mix cortex tools                           # list built-in tools
      mix cortex setup                           # scaffold ~/.cortex/config.json
      mix cortex config                          # show config path + summary
  """
  use Mix.Task
  use Gettext, backend: Cortex.Gettext

  alias Cortex.Config
  alias Cortex.Config.Agent
  alias Cortex.Config.Model

  @impl true
  def run(argv) do
    # Ensure the project is compiled (mix tasks don't recompile by default).
    Mix.Task.run("compile", ["--no-deps-check"])
    dispatch(argv)
  end

  @doc """
  Dispatch a parsed `argv` to the matching command. Shared by the `mix cortex`
  task and the standalone `cortex` escript (`Cortex.CLI`), so both entry points
  behave identically. The escript calls this directly (no Mix at runtime).
  """
  def dispatch(argv) do
    case argv do
      [] -> help()
      ["help"] -> help()
      ["setup" | _] -> with_config(&setup/0)
      ["config" | rest] -> with_config(fn -> config_cmd(rest) end)
      ["tools" | _] -> with_config(&tools/0)
      ["model" | rest] -> with_config(fn -> model_cmd(rest) end)
      ["agent" | rest] -> with_config(fn -> agent_cmd(rest) end)
      ["run" | rest] -> with_app([], fn -> run_cmd(rest) end)
      ["chat" | rest] -> with_app([], fn -> tui_cmd(rest) end)
      ["tui" | rest] -> with_app([], fn -> tui_cmd(rest) end)
      ["serve" | rest] -> with_app([serve: true, gateways: true], fn -> serve_cmd(rest) end)
      # Configuring a gateway only touches the config file — no app needed.
      ["gateway", "telegram", "setup" | _] -> with_config(&telegram_setup/0)
      ["gateway" | rest] -> with_app([gateways: true], fn -> gateway_cmd(rest) end)
      other -> error("unknown command: #{Enum.join(other, " ")}\n") && help()
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
  # what to bring up — `serve: true` opens the HTTP endpoint, `gateways: true`
  # starts the messaging gateways (Telegram). Local `run`/`tui` pass neither.
  defp with_app(opts, fun) do
    serve? = Keyword.get(opts, :serve, false)
    Application.put_env(:cortex, :serve_endpoint, serve?)
    Application.put_env(:cortex, :start_gateways, Keyword.get(opts, :gateways, false))

    if serve? do
      # Phoenix only opens the HTTP listener when the endpoint is told to serve.
      conf = Application.get_env(:cortex, CortexWeb.Endpoint, [])
      Application.put_env(:cortex, CortexWeb.Endpoint, Keyword.put(conf, :server, true))
    end

    {:ok, _} = Application.ensure_all_started(:cortex)
    fun.()
  end

  ###
  ### model
  ###

  # `mix cortex model` (no subcommand): the friendly entry point — show the current
  # default and either switch among saved connections or start the add wizard.
  defp model_cmd([]) do
    case Config.models() do
      [] ->
        info("No model connections yet. Let's add one.")
        add_model_interactively()

      models ->
        default = Config.default_model_name()

        chosen =
          Cortex.TUI.select([:__add__ | models],
            label: bold("Switch default model") <> dim(" (current: #{default || "none"})"),
            render_as: fn
              :__add__ ->
                dim("+ add a new connection")

              m ->
                mark = if m.name == default, do: dim(" ← current"), else: ""
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
          base_url: :string,
          api_key: :string,
          model: :string,
          api: :string,
          max_tokens: :integer,
          temperature: :float,
          default: :boolean
        ]
      )

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
              name: name,
              base_url: base_url,
              api_key: api_key,
              oauth: oauth,
              model: id,
              api: opts[:api] || api_for(base_url),
              max_tokens: opts[:max_tokens],
              temperature: opts[:temperature]
            }

            Config.put_model(model)
            if opts[:default], do: Config.set_default_model(name)
            ok("model connection #{green(name)} saved -> #{model.base_url} (#{green(id)})")
        end
    end
  end

  defp model_cmd(["providers" | _]) do
    info("known providers (pick one with `mix cortex model add NAME`):")

    Cortex.Providers.all()
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

  defp model_cmd(["list" | _]) do
    default = Config.default_model_name()

    case Config.models() do
      [] ->
        info(
          "no model connections. add one:\n  mix cortex model add openrouter --base-url https://openrouter.ai/api/v1 --api-key '${OPENROUTER_API_KEY}' --model anthropic/claude-3.5-sonnet"
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
        info("pinging #{bold(name)} (#{model.model})…")

        case Cortex.LLM.chat(model, [%{"role" => "user", "content" => "ping"}], max_tokens: 5) do
          {:ok, res} ->
            ok("#{green(name)} works — reply: #{String.slice(res.content || "", 0, 60)}")

          {:error, reason} ->
            error("#{name} failed: #{describe(reason)}")
        end
    end
  end

  defp model_cmd(_),
    do: error("usage: mix cortex model [add|list|models|providers|test|remove|default] ...")

  defp add_model_interactively do
    name =
      Owl.IO.input(label: "Name for this connection:")
      |> ensure_unique(model_names(), "model connection")

    model_cmd(["add", name, "--default"])
  end

  # Step 1: "Select a provider" — interactive catalog of known providers.
  defp choose_provider do
    provider =
      Cortex.Providers.all()
      |> Cortex.TUI.select(
        label: bold("Select a provider:"),
        render_as: fn p ->
          case Cortex.Providers.auth_methods(p) do
            [_single] -> p.label
            methods -> [p.label, dim("  (#{length(methods)} auth methods)")]
          end
        end
      )

    choose_auth(provider)
  end

  # Step 2: "Auth method for {provider}" — submenu (auto-picks when only one).
  defp choose_auth(provider) do
    case Cortex.Providers.auth_methods(provider) do
      [single] ->
        apply_auth(provider, single)

      methods ->
        method =
          Cortex.TUI.select(methods,
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
    info(dim("local provider — no API key needed"))
    {provider.base_url, nil, nil}
  end

  # Subscription sign-in: run the browser PKCE flow when the method declares one.
  defp apply_auth(provider, %{type: :oauth, oauth_flow: flow} = method) when is_map(flow) do
    base_url = method[:base_url] || provider.base_url

    case Cortex.OAuth.login(flow) do
      {:ok, %{access: access} = creds} when is_binary(access) ->
        ok("signed in — subscription token captured")

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

    if api_key && Cortex.Config.interpolate(api_key) in [nil, ""] do
      info(
        dim("note: api key #{api_key} resolves to empty — export the env var, or this may 401")
      )
    end

    Cortex.LLM.list_models(probe)
  end

  # Step 3: "Loading available models" → "Default model" picker. Tries the live
  # catalog first (including the Codex subscription's own /models endpoint); if
  # that returns nothing, falls back to a curated list, then to manual entry.
  defp pick_model(base_url, api_key) do
    info(dim("Loading available models…"))

    case fetch_models(base_url, api_key) do
      {:ok, [_ | _] = ids} ->
        choose_model(ids)

      _ ->
        case curated_models(base_url) do
          [_ | _] = ids ->
            choose_model(ids)

          [] ->
            info(dim("This provider doesn't list models — enter the model id."))
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

  defp auth_methods, do: Enum.flat_map(Cortex.Providers.all(), &(&1[:auth] || []))

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

    Cortex.TUI.select(ids, label: bold("Select the default model:"))
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

  defp agent_cmd(["add", name | rest]) do
    {opts, _} =
      OptionParser.parse!(rest,
        strict: [
          model: :string,
          prompt: :string,
          description: :string,
          tools: :string,
          max_iterations: :integer,
          temperature: :float,
          default: :boolean
        ]
      )

    tools =
      case opts[:tools] do
        nil -> Cortex.Tools.names()
        "" -> []
        str -> str |> String.split(",") |> Enum.map(&String.trim/1)
      end

    agent = %Agent{
      name: name,
      description: opts[:description],
      model: opts[:model],
      system_prompt: opts[:prompt] || "You are Cortex, a helpful AI agent.",
      tools: tools,
      max_iterations: opts[:max_iterations] || 12,
      temperature: opts[:temperature]
    }

    Config.put_agent(agent)
    if opts[:default], do: Config.set_default_agent(name)
    ok("agent #{green(name)} saved (tools: #{Enum.join(tools, ", ")})")
  end

  defp agent_cmd(["list" | _]) do
    default = Config.default_agent_name()

    case Config.agents() do
      [] ->
        info(
          "no agents. add one:\n  mix cortex agent add assistant --model <model> --prompt \"You are helpful.\""
        )

      agents ->
        Enum.each(agents, fn a ->
          mark = if a.name == default, do: " #{green("(default)")}", else: ""

          IO.puts(
            "#{bold(a.name)}#{mark}\n  model: #{a.model || "(default)"}\n  tools: #{Enum.join(a.tools, ", ")}"
          )
        end)
    end
  end

  defp agent_cmd(["remove", name | _]) do
    Config.delete_agent(name)
    ok("removed agent #{name}")
  end

  defp agent_cmd(["rename", old, new | _]) do
    case Config.rename_agent(old, new) do
      {:error, :not_found} ->
        error("unknown agent: #{old}")

      _ ->
        Cortex.Agent.Workspace.rename(old, new)
        ok("agent #{green(old)} → #{green(new)} (workspace moved)")
    end
  end

  defp agent_cmd(["default", name | _]) do
    Config.set_default_agent(name)
    ok("default agent -> #{name}")
  end

  defp agent_cmd(_), do: error("usage: mix cortex agent add|list|rename|remove|default ...")

  ###
  ### run / chat
  ###

  defp run_cmd([]), do: error("usage: mix cortex run [AGENT] \"prompt\"")

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
    case Cortex.Agent.oneshot(agent_name, prompt,
           stream: true,
           on_event: Cortex.Gateways.TUI.stream_events(),
           authorize: Cortex.Gateways.TUI.authorizer()
         ) do
      {:ok, _content, _msgs} -> IO.puts("")
      {:error, reason} -> error("\n#{inspect(reason)}")
    end
  end

  # The interactive console gateway lives in Cortex.Gateways.TUI; just resolve the
  # agent and hand off. `chat` and `tui` both land here.
  defp tui_cmd(args) do
    # Accept the agent as a positional (`tui NAME`) or a flag (`tui --agent NAME`),
    # and an optional `--session KEY` to resume/separate console sessions.
    {opts, rest} = OptionParser.parse!(args, strict: [agent: :string, session: :string])
    agent_name = opts[:agent] || List.first(rest) || Config.default_agent_name()

    case agent_name && Config.get_agent(agent_name) do
      nil ->
        error(
          "no agent. create one with `mix cortex agent add ...` or pass one: mix cortex tui [--agent NAME]"
        )

      agent ->
        Cortex.Gateways.TUI.start(agent.name, opts[:session])
    end
  end

  ###
  ### serve / gateway
  ###

  defp serve_cmd(_rest) do
    port = CortexWeb.Endpoint.config(:http)[:port] || 4000

    ok("Cortex serving on http://localhost:#{port}  (override with PORT=NNNN)")

    info("""
      OpenAI API : POST http://localhost:#{port}/v1/chat/completions
      Models     : GET  http://localhost:#{port}/v1/models
      Health     : GET  http://localhost:#{port}/health
      WebSocket  : ws://localhost:#{port}/socket/websocket  (topic agent:default)
    """)

    Process.sleep(:infinity)
  end

  defp gateway_cmd(["telegram" | _]) do
    if Cortex.Gateways.Telegram.enabled?() do
      ok("Telegram gateway running. Press Ctrl-C to stop.")
      Process.sleep(:infinity)
    else
      error("no Telegram bot token configured. Run: mix cortex gateway telegram setup")
    end
  end

  defp gateway_cmd(_), do: error("usage: mix cortex gateway telegram [setup]")

  # Interactive Telegram config — token, optional agent, optional chat allowlist.
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
      info(dim("Start it with:  mix cortex gateway telegram"))
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

        case Cortex.TUI.select([default_label | names],
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

  # Guided, end-to-end onboarding: provider → auth → model → agent → tools, then
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
    info(bold("Cortex setup") <> dim(" — you're already configured. What do you want to do?\n"))

    options = [
      {:model, "Model connection — add or switch the default"},
      {:agent, "Agent — add or set the default"},
      {:telegram, "Telegram gateway"},
      {:language, "Language for system messages"},
      {:full, "Run the full guided setup"},
      {:done, "Done"}
    ]

    {action, _label} =
      Cortex.TUI.select(options,
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
    end
  end

  defp first_run_setup do
    info(bold("Welcome to Cortex setup") <> " — let's get you ready.\n")
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
            ok("model #{green(name)} → #{model_id}")

            info("\n" <> bold("Step 2/2 · Agent"))
            add_agent()
            maybe_setup_telegram()
            info("\n" <> green("✓ All set!") <> "  Try:  " <> bold("cortex run \"hello\""))
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
      Cortex.TUI.select(@locales,
        label: bold("Language for system messages") <> dim(" (current: #{Config.locale()})"),
        render_as: fn {_code, label} -> label end
      )

    Config.set_locale(code)
    ok("language → #{code}")
  end

  # Add an agent bound to the current default model connection.
  defp add_agent do
    agent_name =
      Owl.IO.input(label: "Agent name:", optional: true)
      |> blank_default("assistant")
      |> ensure_unique(agent_names(), "agent")

    system_prompt =
      Owl.IO.input(label: "System prompt:", optional: true)
      |> blank_default("You are Cortex, a helpful AI agent.")

    tools =
      case Cortex.TUI.multiselect(Cortex.Tools.names(),
             label:
               bold("Select tools") <> dim(" (numbers, space/comma separated; blank = all):"),
             render_as: &tool_render/1
           ) do
        [] -> Cortex.Tools.names()
        picked -> picked
      end

    Config.put_agent(%Agent{
      name: agent_name,
      model: Config.default_model_name(),
      system_prompt: system_prompt,
      tools: tools,
      max_iterations: 12
    })

    Config.set_default_agent(agent_name)
    ok("agent #{green(agent_name)} (tools: #{Enum.join(tools, ", ")})")
    :ok
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

  # Suggest a connection name from the host (api.openai.com → "openai").
  defp default_conn_name(base_url) do
    host = URI.parse(base_url).host || "model"

    host
    |> String.split(".")
    |> Enum.reject(&(&1 in ["api", "www"]))
    |> List.first()
    |> Kernel.||("model")
  end

  defp tool_render(name) do
    case Cortex.Tools.get(name) do
      nil ->
        name

      mod ->
        %{"function" => %{"description" => desc}} = mod.spec()
        [name, dim("  — " <> String.slice(desc, 0, 48))]
    end
  end

  defp config_cmd(_) do
    info("config file: #{Config.path()}")
    info("default model: #{Config.default_model_name() || "(none)"}")
    info("default agent: #{Config.default_agent_name() || "(none)"}")
    info("models: #{Config.models() |> Enum.map(& &1.name) |> Enum.join(", ")}")
    info("agents: #{Config.agents() |> Enum.map(& &1.name) |> Enum.join(", ")}")
  end

  defp tools do
    info("built-in tools:")

    Enum.each(Cortex.Tools.all(), fn mod ->
      %{"function" => %{"description" => desc}} = mod.spec()
      IO.puts("  #{bold(mod.name())} — #{desc}")
    end)
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
  defp bold(s), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
