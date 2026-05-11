defmodule Pepe.Doctor do
  @moduledoc """
  Health checks for the whole setup - the **verify** half of do -> verify -> correct.

  Run after changing something (or any time) to catch what's broken *before* it
  bites: unset `${ENV}` secrets, agents pointing at missing models, unknown tools in
  an allowlist, invalid cron schedules/timezones, unreachable Telegram bots and MCP
  servers.

  Two tiers so it's cheap by default:

    * `checks/0` - offline checks only (config + on-disk state). Fast, no network.
      Covers: unresolved `${ENV}` secrets, plaintext secrets and a missing dashboard
      password (security), agents/crons/channels pointing at missing pieces, orphan
      agent directories on disk, and plugins/skills that won't load.
    * `checks/1` with `live: true` - also probes the outside world: a newer release on
      GitHub, Telegram `getMe` per bot, a `/models` ping per model connection, and an
      MCP launch + tools list per server.

  Each check is `{area, subject, :ok | {:warn, msg} | {:error, msg}}`.
  """

  alias Pepe.Config

  @type status :: :ok | {:warn, String.t()} | {:error, String.t()}
  @type check :: {String.t(), String.t(), status()}

  @spec checks(keyword()) :: [check()]
  def checks(opts \\ []) do
    offline =
      env_checks() ++
        security_checks() ++
        billing_checks() ++
        agent_checks() ++
        cron_checks() ++
        webhook_checks() ++
        state_checks() ++
        plugin_checks() ++
        skill_checks()

    if opts[:live] do
      offline ++ version_checks() ++ telegram_checks() ++ model_checks() ++ mcp_checks()
    else
      offline
    end
  end

  @doc "True when no check failed (warnings are fine)."
  def healthy?(checks), do: not Enum.any?(checks, &match?({_, _, {:error, _}}, &1))

  ###
  ### offline checks
  ###

  # Every ${ENV_VAR} referenced anywhere in the config must resolve.
  defp env_checks do
    Config.load()
    |> collect_env_refs()
    |> Enum.uniq()
    |> Enum.map(fn var ->
      if System.get_env(var) in [nil, ""] do
        {"env", var, {:error, "referenced in config but not set in the environment"}}
      else
        {"env", var, :ok}
      end
    end)
  end

  defp collect_env_refs(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_env_refs/1)

  defp collect_env_refs(value) when is_list(value),
    do: Enum.flat_map(value, &collect_env_refs/1)

  defp collect_env_refs(value) when is_binary(value) do
    ~r/\$\{([A-Z0-9_]+)\}/
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
  end

  defp collect_env_refs(_), do: []

  # A subscription connection whose monthly fee we were never told still bills the client
  # correctly (that is priced off the API list, not off what we pay), but it makes the
  # reported margin an upper bound: the fee never appears against it. Worth saying out loud,
  # because the number looks right and isn't.
  defp billing_checks do
    Config.models()
    |> Enum.filter(&Pepe.Config.Model.subscription?/1)
    |> Enum.map(fn model ->
      if is_number(model.monthly_cost) do
        {"billing", model.name, :ok}
      else
        {"billing", model.name, {:warn, "subscription with no monthly_cost - its fee is missing from your margin"}}
      end
    end)
  end

  # Agents: model exists, tools known (builtin/plugin/mcp).
  defp agent_checks do
    known = MapSet.new(Pepe.Tools.names())

    Enum.flat_map(Config.agents(), fn agent ->
      model_check =
        cond do
          is_nil(agent.model) and is_nil(Config.default_model_name()) ->
            {"agent", agent.name, {:error, "no model (agent has none and no default is set)"}}

          agent.model && is_nil(Config.get_model(agent.model)) ->
            {"agent", agent.name, {:error, "model #{agent.model} doesn't exist"}}

          true ->
            {"agent", agent.name, :ok}
        end

      unknown =
        agent.tools
        |> Enum.reject(&(MapSet.member?(known, &1) or Pepe.MCP.mcp_tool?(&1)))

      tools_check =
        case unknown do
          [] -> []
          list -> [{"agent", agent.name, {:warn, "unknown tools: #{Enum.join(list, ", ")}"}}]
        end

      [model_check | tools_check] ++ utility_check(agent)
    end)
  end

  # A `utility_model` pointing nowhere is treated as unset (Pepe.Agent.Utility deliberately
  # refuses to fall back to the agent's own model, so that a typo cannot be the thing that
  # starts spending). Silently, though - the chores still get done, just the cheap way - and
  # a setting that looks applied and isn't is exactly what a diagnostic is for.
  defp utility_check(%{utility_model: name} = agent) when is_binary(name) and name != "" do
    if Config.get_model(name) do
      []
    else
      [
        {"agent", agent.name, {:warn, "utility_model #{name} doesn't exist - chores fall back to the no-model path"}}
      ]
    end
  end

  defp utility_check(_agent), do: []

  # Crons: schedule parses, timezone valid, agent exists.
  defp cron_checks do
    Enum.flat_map(Config.crons(), fn cron ->
      [
        case Pepe.Cron.parse(cron.schedule) do
          {:ok, _} -> {"cron", cron.id, :ok}
          {:error, msg} -> {"cron", cron.id, {:error, "invalid schedule: #{msg}"}}
        end,
        case DateTime.now(cron.timezone) do
          {:ok, _} -> {"cron", "#{cron.id} tz", :ok}
          _ -> {"cron", "#{cron.id} tz", {:error, "unknown timezone #{cron.timezone}"}}
        end,
        if Config.get_agent(cron.agent) do
          {"cron", "#{cron.id} agent", :ok}
        else
          {"cron", "#{cron.id} agent", {:error, "agent #{cron.agent} doesn't exist"}}
        end
      ]
    end)
  end

  # Security: secrets stored in the clear, and a server with no dashboard password.
  defp security_checks do
    secret_checks =
      case plaintext_secrets(Config.load(), []) do
        [] ->
          [{"security", "secrets", :ok}]

        paths ->
          Enum.map(paths, fn path ->
            {"security", "plaintext secret at #{path}",
             {:warn,
              "in the clear - revoke and reissue it (it is in the file, and if it was typed into a chat it also reached a model provider), then refer to it as ${ENV_VAR}"}}
          end)
      end

    password_check =
      if Config.dashboard_auth_required?() do
        {"security", "dashboard password", :ok}
      else
        {"security", "dashboard password", {:warn, "not set; set one (pepe dashboard password) before exposing the server publicly"}}
      end

    secret_checks ++ [password_check]
  end

  # Walk the config, flagging a credential written in the clear. Returns dotted paths like
  # "models.m1.api_key" or "mcp.github.env.GITHUB_TOKEN".
  #
  # Two ways to be a finding, because a secret hides in two ways. A key whose *name* says so
  # (`api_key`, and now `GITHUB_TOKEN` and `BRAVE_API_KEY`, matched on word parts rather than
  # by exact name - which is why they used to sail straight past this check). Or a *value*
  # that is unmistakably a credential (`sk-...`, `ghp_...`) whatever it was filed under, which
  # is how a token passed positionally in an argument list gets caught: there, it has no key
  # name to give it away.
  defp plaintext_secrets(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      here = path ++ [to_string(k)]

      cond do
        is_map(v) or is_list(v) -> plaintext_secrets(v, here)
        Pepe.Secrets.secret_key?(k) and plaintext_value?(v) -> [Enum.join(here, ".")]
        Pepe.Secrets.plaintext?(v) -> [Enum.join(here, ".")]
        true -> []
      end
    end)
  end

  defp plaintext_secrets(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> plaintext_secrets(v, path ++ [Integer.to_string(i)]) end)
  end

  defp plaintext_secrets(_v, _path), do: []

  # For a key that already announces itself as a secret, any non-empty value that is not an
  # ${ENV_VAR} reference is a finding - it does not also have to look like a credential.
  defp plaintext_value?(v) when is_binary(v), do: v != "" and not Pepe.Secrets.reference?(v)
  defp plaintext_value?(_v), do: false

  # Channels (inbound webhook providers): provider known, agent exists, required creds
  # present. These are inbound, so unlike Telegram they have no getMe-style live probe -
  # this is the config-validity check for them.
  defp webhook_checks do
    Enum.flat_map(Config.webhooks(), fn {slug, entry} ->
      case entry["provider"] && Pepe.Webhooks.provider(entry["provider"]) do
        nil -> [{"channel", slug, {:error, "unknown provider #{inspect(entry["provider"])}"}}]
        mod -> [webhook_agent_check(slug, entry) | webhook_creds_check(slug, entry, mod)]
      end
    end)
  end

  defp webhook_agent_check(slug, entry) do
    if entry["agent"] && Config.get_agent(entry["agent"]) do
      {"channel", slug, :ok}
    else
      {"channel", slug, {:error, "agent #{inspect(entry["agent"])} doesn't exist"}}
    end
  end

  defp webhook_creds_check(slug, entry, mod) do
    config = entry["config"] || %{}

    missing =
      mod.config_schema()
      |> Enum.filter(&(required_config_field?(&1) and config[&1["key"]] in [nil, ""]))
      |> Enum.map(& &1["key"])

    case missing do
      [] -> []
      keys -> [{"channel", "#{slug} config", {:warn, "missing required fields: #{Enum.join(keys, ", ")}"}}]
    end
  end

  defp required_config_field?(field), do: field["type"] != "select" and field["required"] != false

  # State integrity: agent directories on disk with no matching config entry. They keep
  # sessions/memory but config-driven routing ignores them, so flag them.
  defp state_checks do
    root = orphan_agent_dirs(Path.join(Config.home(), "agents"), Config.agents_in(nil), nil)

    company =
      Enum.flat_map(Config.companies(), fn co ->
        orphan_agent_dirs(Path.join([Config.home(), "companies", co, "agents"]), Config.agents_in(co), co)
      end)

    case root ++ company do
      [] -> [{"state", "agent directories", :ok}]
      orphans -> orphans
    end
  end

  defp orphan_agent_dirs(dir, agents, company) do
    known = MapSet.new(agents, &Pepe.Company.name_of(&1.name))

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.reject(&MapSet.member?(known, &1))
        |> Enum.map(&orphan_agent_dir_check(&1, company))

      _ ->
        []
    end
  end

  defp orphan_agent_dir_check(entry, company) do
    label = if company, do: "#{company}/#{entry}", else: entry
    {"state", "orphan agent dir #{label}", {:warn, "on disk but not in config; remove it or re-add the agent"}}
  end

  # Plugins: packages with a broken/missing manifest, and any `.exs` that won't parse.
  defp plugin_checks do
    packages = Pepe.Plugins.packages()

    manifest =
      packages
      |> Enum.filter(&(&1.kind == :package and is_nil(&1.manifest)))
      |> Enum.map(fn p -> {"plugin", p.name, {:warn, "package has no valid manifest.json"}} end)

    parse =
      Path.wildcard(Path.join(Pepe.Plugins.dir(), "**/*.exs"))
      |> Enum.flat_map(fn path ->
        with {:ok, src} <- File.read(path),
             {:error, _} <- Code.string_to_quoted(src) do
          [{"plugin", Path.relative_to(path, Pepe.Plugins.dir()), {:error, "doesn't parse"}}]
        else
          _ -> []
        end
      end)

    cond do
      manifest != [] or parse != [] -> manifest ++ parse
      packages == [] -> []
      true -> [{"plugin", "installed plugins", :ok}]
    end
  end

  # Skills: user-installed skill files that are empty (built-ins are shipped and trusted).
  defp skill_checks do
    dir = Pepe.Skills.user_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&empty_skill_check(dir, &1))

      _ ->
        []
    end
  end

  defp empty_skill_check(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, body} ->
        if String.trim(body) == "", do: [{"skill", Path.rootname(file), {:warn, "skill file is empty"}}], else: []

      _ ->
        []
    end
  end

  ###
  ### live checks (network)
  ###

  # A newer published release than the running binary means an update is available.
  defp version_checks do
    current = to_string(Application.spec(:pepe, :vsn) || "")

    case latest_release() do
      {:ok, latest} when current != "" ->
        if newer?(latest, current) do
          [
            {"version", "v#{current}",
             {:warn, "update available: v#{latest} (reinstall: curl -fsSL https://pepe-agent.com/install.sh | sh)"}}
          ]
        else
          [{"version", "v#{current}", :ok}]
        end

      {:ok, _} ->
        [{"version", "release", :ok}]

      {:error, reason} ->
        [{"version", "release", {:warn, "couldn't check for updates: #{describe(reason)}"}}]
    end
  end

  defp latest_release do
    case Req.get("https://api.github.com/repos/pepe-agent/pepe/releases/latest",
           receive_timeout: 10_000,
           headers: [{"accept", "application/vnd.github+json"}]
         ) do
      {:ok, %{status: 200, body: %{"tag_name" => "v" <> v}}} -> {:ok, v}
      {:ok, %{status: 200, body: %{"tag_name" => v}}} when is_binary(v) -> {:ok, v}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      other -> other
    end
  end

  # Semver-compare when both parse; otherwise a plain inequality is the best we can do.
  defp newer?(latest, current) do
    case {Version.parse(latest), Version.parse(current)} do
      {{:ok, l}, {:ok, c}} -> Version.compare(l, c) == :gt
      _ -> latest != current
    end
  end

  defp telegram_checks do
    Enum.map(Config.telegram_bots(), fn bot ->
      name = bot["name"]
      token = Config.interpolate(bot["bot_token"])

      cond do
        token in [nil, ""] ->
          {"telegram", name, {:error, "token doesn't resolve (env var unset?)"}}

        bot["enabled"] == false ->
          {"telegram", name, {:warn, "disabled"}}

        true ->
          telegram_getme(name, token)
      end
    end)
  end

  defp telegram_getme(name, token) do
    case Req.get("https://api.telegram.org/bot#{token}/getMe", receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"username" => u}}}} ->
        {"telegram", name, {:warn, "ok (@#{u})"} |> ok_if_ok()}

      {:ok, %{status: 401}} ->
        {"telegram", name, {:error, "invalid token (401)"}}

      other ->
        {"telegram", name, {:error, "unreachable: #{describe(other)}"}}
    end
  end

  # A successful getMe is :ok, not a warning - helper keeps the branch tidy.
  defp ok_if_ok({:warn, "ok" <> _}), do: :ok
  defp ok_if_ok(other), do: other

  defp model_checks do
    Enum.map(Config.models(), fn model ->
      case Pepe.LLM.list_models(model) do
        {:ok, _} -> {"model", model.name, :ok}
        {:error, reason} -> {"model", model.name, {:error, "unreachable: #{describe(reason)}"}}
      end
    end)
  end

  defp mcp_checks do
    Enum.map(Config.mcp_servers(), fn {name, _cfg} ->
      case Pepe.MCP.tools(name) do
        {:ok, tools} -> {"mcp", name, ok_note("#{length(tools)} tools")}
        {:error, reason} -> {"mcp", name, {:error, "unreachable: #{describe(reason)}"}}
      end
    end)
  end

  defp ok_note(_note), do: :ok

  defp describe({:ok, %{status: status}}), do: "HTTP #{status}"
  defp describe({:error, reason}), do: describe(reason)
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other) |> String.slice(0, 120)
end
