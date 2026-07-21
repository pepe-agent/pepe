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
      agent directories on disk, plugins/skills that won't load, and an unrecognized
      top-level config key (usually a typo doing nothing silently).
    * `checks/1` with `live: true` - also probes the outside world: a newer release on
      GitHub, Telegram `getMe` per bot, a `/models` ping per model connection, and an
      MCP launch + tools list per server.

  Each check is `{area, subject, :ok | {:warn, msg} | {:error, msg}}`.
  """

  alias Pepe.Config

  import Bitwise, only: [&&&: 2]

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
        migration_checks() ++
        plugin_checks() ++
        skill_checks() ++
        unknown_key_checks()

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

  # Every top-level section this codebase actually reads or writes somewhere, kept by hand
  # rather than derived - `Config.load/0` on a config that has never set a given section
  # simply omits it, so there is no way to enumerate this from a live config, only from
  # reading the code. A key that isn't here is almost always a typo ("telegran" instead of
  # "telegram") silently doing nothing rather than the error it looks like it should be -
  # this check exists to turn that silence into a warning. `companies` and the legacy,
  # pre-project `root` billing shape are both migrated away by `migrate/1` on first load, so
  # they are listed here only so a config file that hasn't been loaded by this process yet
  # doesn't warn about its own soon-to-be-migrated shape.
  @known_top_level_keys ~w(
    agents api_tokens board_cards boards commitments companies crons currency
    dashboard default_agent default_model default_project hooks locale mcp media
    models plugins projects review_writes root sandbox secrets server
    telegram telegram_topics telegrams timezone watches webhooks
  )

  defp unknown_key_checks do
    unknown =
      Config.load()
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_top_level_keys))

    case unknown do
      [] -> [{"config", "top-level keys", :ok}]
      keys -> Enum.map(keys, &{"config", &1, {:warn, "unknown top-level config key - a typo? it's doing nothing"}})
    end
  end

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
      case plaintext_secrets(Config.load(), []) ++ commitment_plaintext_secrets() do
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

    secret_checks ++ [password_check] ++ file_perms_checks()
  end

  # The config file can hold a raw credential, so it must not be readable or writable by other
  # users on the machine. Flags a config or home that any group/other can read or write. POSIX
  # only: on a filesystem with no Unix mode bits (Windows) `File.stat` gives 0 and this is silent.
  defp file_perms_checks do
    [{Config.path(), "config file", 0o077}, {Config.home(), "config directory", 0o022}]
    |> Enum.flat_map(fn {target, label, mask} -> perm_check(target, label, mask) end)
  end

  defp perm_check(target, label, mask) do
    case File.stat(target) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& mask) != 0 ->
        [
          {"security", "#{label} permissions",
           {:warn,
            "#{target} is accessible to other users on this machine (mode #{Integer.to_string(mode &&& 0o777, 8)}); " <>
              "tighten it with `chmod #{if mask == 0o077, do: "600", else: "700"} #{target}`"}}
        ]

      _ ->
        []
    end
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
  #
  # `origin.key` is one legitimate exception to the name check: Watch and Commitment both
  # carry an `origin` map (`Watch.Delivery.origin_from_ctx/1`) whose `key` is a session key -
  # the same string already shown plainly in the dashboard sidebar, not a credential. Matching
  # "key" as a whole word (needed to catch a real `some_key: "sk-..."` typo) makes every one of
  # them a false positive otherwise; the value-shaped check right below still catches a genuine
  # credential that somehow ended up there anyway.
  #
  # An OAuth-connected model's own `oauth` map is a second: `token_url`/`client_id`/
  # `token_content_type`/`provider`/`expires_at` are written verbatim from the provider's
  # fixed flow spec in `Pepe.Providers` (see `Pepe.OAuth.subscription_connection/4`), never
  # typed in by anyone - `token_url` is the provider's own public token endpoint, `client_id`
  # is the public identifier of a PKCE flow that has no client_secret to begin with. Flagging
  # them the same as a real leaked token drowns the ones that matter in noise about a URL and
  # an enum. `refresh`, and a model's own `api_key` once it has that `oauth` map, are the
  # opposite case: real live credentials, correctly excluded here too, but for a different
  # reason - `Pepe.OAuth.persist_refresh/3` rewrites both on every token refresh, so there is
  # no `${ENV_VAR}` either could ever be turned into (the app itself needs write access to
  # rotate it); what protects them is the config file's own permissions, already covered by
  # `file_perms_checks/0` below, not this warning's "move it to an env var" advice.
  defp plaintext_secrets(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      here = path ++ [to_string(k)]

      cond do
        is_map(v) or is_list(v) -> plaintext_secrets(v, here)
        oauth_managed_key?(k, path, map) -> []
        Pepe.Secrets.secret_key?(k) and not origin_routing_key?(k, path) and plaintext_value?(v) -> [Enum.join(here, ".")]
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

  # Commitments moved off config.json onto Pepe.Repo (see Pepe.Config.Commitment) - the
  # generic walk above only ever sees config.json, so without this, a credential that
  # ended up in a commitment's `origin` map (or anywhere else in it) would silently stop
  # being caught the moment it left the file. The `origin.key`-is-a-session-key-not-a-
  # credential exception (origin_routing_key?/2) applies here exactly as it does to a
  # watch's origin, since it is the same shape and the same reasoning.
  defp commitment_plaintext_secrets do
    Config.commitments()
    |> Enum.flat_map(fn c ->
      c
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :normalized_text])
      |> plaintext_secrets(["commitments", c.id])
    end)
  end

  @oauth_protocol_fields ~w(token_url token_content_type client_id provider expires_at)

  # Order matters: the literal "api_key" clause must be tried before the generic one below,
  # or it would never be reached (a bare variable pattern matches anything).
  defp oauth_managed_key?("api_key", _path, map), do: is_map(map["oauth"])

  defp oauth_managed_key?(k, path, _map) do
    key = to_string(k)
    (key in @oauth_protocol_fields or key == "refresh") and List.last(path) == "oauth"
  end

  defp origin_routing_key?(k, path), do: to_string(k) == "key" and List.last(path) == "origin"

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
    orphans =
      Enum.flat_map(Config.projects(), fn %{"slug" => slug} ->
        orphan_agent_dirs(Path.join([Config.home(), "projects", slug, "agents"]), Config.agents_in(slug), slug)
      end)

    case orphans do
      [] -> [{"state", "agent directories", :ok}]
      orphans -> orphans
    end
  end

  # A legacy "commitments"/"watches" section left in config.json (from before those moved
  # to Pepe.Repo) means their one-time migration command was never run - every entry that
  # was there before the upgrade is invisible to Config.commitments/0 / Config.watches/0
  # now, silently: no error, no crash, they just stop firing. Nothing else in the codebase
  # would ever surface that on its own.
  defp migration_checks do
    config = Config.load()

    legacy_check(config, "commitments", "mix pepe config migrate-commitments") ++
      legacy_check(config, "watches", "mix pepe config migrate-data") ++
      legacy_check(config, "boards", "mix pepe config migrate-data") ++
      legacy_check(config, "board_cards", "mix pepe config migrate-data")
  end

  defp legacy_check(config, key, command) do
    if Map.has_key?(config, key) do
      [{"state", "unmigrated #{key}", {:warn, "config.json still has a \"#{key}\" section - run `#{command}` to import it"}}]
    else
      []
    end
  end

  defp orphan_agent_dirs(dir, agents, project) do
    known = MapSet.new(agents, &Pepe.Project.name_of(&1.name))

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.reject(&MapSet.member?(known, &1))
        |> Enum.map(&orphan_agent_dir_check(&1, project))

      _ ->
        []
    end
  end

  defp orphan_agent_dir_check(entry, project) do
    label = if project, do: "#{project}/#{entry}", else: entry
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
