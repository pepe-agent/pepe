defmodule Cortex.Config do
  @moduledoc """
  File-backed configuration store, the single source of truth for model
  connections, agents and gateway credentials.

  Lives at `~/.cortex/config.json` by default. Override the directory with the
  `CORTEX_HOME` env var, or point straight at a file with `CORTEX_CONFIG`.

  The on-disk shape:

      {
        "default_model": "openrouter",
        "models": { "openrouter": { ...Cortex.Config.Model } },
        "default_agent": "assistant",
        "agents": { "assistant": { ...Cortex.Config.Agent } },
        "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [] },
        "server": { "port": 4000 }
      }

  Secrets may be written literally or as `${ENV_VAR}` placeholders; they are
  interpolated against the environment at read time, never persisted expanded.
  """

  alias Cortex.Config.Agent
  alias Cortex.Config.Cron
  alias Cortex.Config.Model

  @doc "Absolute path to the config directory (created on demand)."
  def home do
    System.get_env("CORTEX_HOME") || Path.join(System.user_home!(), ".cortex")
  end

  @doc "Absolute path to the config file."
  def path do
    System.get_env("CORTEX_CONFIG") || Path.join(home(), "config.json")
  end

  @doc "Load the raw config map, returning sane defaults when the file is absent."
  def load do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map
          _ -> default()
        end

      {:error, _} ->
        default()
    end
  end

  defp default do
    %{
      "default_model" => nil,
      "models" => %{},
      "default_agent" => nil,
      "agents" => %{},
      "telegram" => %{"bot_token" => "${TELEGRAM_BOT_TOKEN}", "allowed_chats" => []},
      "server" => %{"port" => 4000}
    }
  end

  @doc "Persist the raw config map, creating the directory if needed."
  def save(map) when is_map(map) do
    File.mkdir_p!(home())
    File.write!(path(), Jason.encode!(map, pretty: true))
    map
  end

  ###
  ### Models
  ###

  @doc "List all model connections as structs."
  def models do
    load()
    |> Map.get("models", %{})
    |> Enum.map(fn {name, m} -> Model.from_map(Map.put(m, "name", name)) end)
  end

  @doc "Fetch a model connection by name."
  def get_model(name) do
    case load() |> get_in(["models", name]) do
      nil -> nil
      m -> Model.from_map(Map.put(m, "name", name))
    end
  end

  def get_model!(name) do
    get_model(name) || raise "unknown model connection: #{inspect(name)}"
  end

  @doc "Insert or update a model connection."
  def put_model(%Model{name: name} = model) do
    load()
    |> update_in(["models"], fn m -> Map.put(m || %{}, name, encode(model)) end)
    |> maybe_default("default_model", name)
    |> save()
  end

  def delete_model(name) do
    load()
    |> update_in(["models"], &Map.delete(&1 || %{}, name))
    |> clear_default_if("default_model", name)
    |> save()
  end

  def default_model_name, do: load()["default_model"]

  def default_model do
    case default_model_name() do
      nil -> nil
      name -> get_model(name)
    end
  end

  def set_default_model(name) do
    load() |> Map.put("default_model", name) |> save()
  end

  ###
  ### Agents
  ###

  def agents do
    load()
    |> Map.get("agents", %{})
    |> Enum.map(fn {name, a} -> Agent.from_map(Map.put(a, "name", name)) end)
  end

  def get_agent(name) do
    case load() |> get_in(["agents", name]) do
      nil -> nil
      a -> Agent.from_map(Map.put(a, "name", name))
    end
  end

  def get_agent!(name) do
    get_agent(name) || raise "unknown agent: #{inspect(name)}"
  end

  def put_agent(%Agent{name: name} = agent) do
    load()
    |> update_in(["agents"], fn a -> Map.put(a || %{}, name, encode(agent)) end)
    |> maybe_default("default_agent", name)
    |> save()
  end

  @doc "Persistently approve `tool` for `agent_name` (the `:always` permission grant)."
  def allow_tool(agent_name, tool) do
    case get_agent(agent_name) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | auto_approve: Enum.uniq([tool | agent.auto_approve])})
    end
  end

  @doc "Allow `from` to message `to` (a directed route; `to → from` is unaffected)."
  def allow_message(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_message: Enum.uniq(agent.can_message ++ [to])})
    end
  end

  @doc "Remove the `from → to` route."
  def disallow_message(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_message: List.delete(agent.can_message, to)})
    end
  end

  @doc """
  May `admin` administer the agent named `target`? Authority defaults to CLOSED:

    * `can_manage == nil` → itself only (a mild default).
    * `[]` → nobody, not even itself (a locked child).
    * `[names]` → exactly those (list is exhaustive — include its own name to also
      manage itself).
    * `["*"]` → everyone (an explicit super-admin, never implicit).
  """
  def can_manage?(%Agent{name: name, can_manage: cm}, target) do
    cond do
      is_nil(cm) -> to_string(target) == to_string(name)
      "*" in cm -> true
      true -> to_string(target) in Enum.map(cm, &to_string/1)
    end
  end

  @doc "Grant `from` management authority over `to` (directed; list is exhaustive)."
  def allow_manage(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_manage: Enum.uniq((agent.can_manage || []) ++ [to])})
    end
  end

  @doc "Revoke `from`'s authority over `to`."
  def disallow_manage(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_manage: List.delete(agent.can_manage || [], to)})
    end
  end

  def delete_agent(name) do
    load()
    |> update_in(["agents"], &Map.delete(&1 || %{}, name))
    |> clear_default_if("default_agent", name)
    |> save()
  end

  @doc "Rename an agent (config key + name + default pointer). Does not move files."
  def rename_agent(old, new) do
    config = load()
    agents = config["agents"] || %{}

    case Map.fetch(agents, old) do
      {:ok, agent_map} ->
        agents =
          agents
          |> Map.delete(old)
          |> Map.put(new, Map.put(agent_map, "name", new))

        config
        |> Map.put("agents", agents)
        |> then(fn c ->
          if c["default_agent"] == old, do: Map.put(c, "default_agent", new), else: c
        end)
        |> save()

      :error ->
        {:error, :not_found}
    end
  end

  def default_agent_name, do: load()["default_agent"]

  def default_agent do
    case default_agent_name() do
      nil -> nil
      name -> get_agent(name)
    end
  end

  def set_default_agent(name) do
    load() |> Map.put("default_agent", name) |> save()
  end

  @doc """
  Resolve the model connection an agent should use, falling back to the global
  default model when the agent doesn't pin one.
  """
  def model_for_agent(%Agent{model: nil}), do: default_model()
  def model_for_agent(%Agent{model: name}), do: get_model(name) || default_model()

  @doc """
  The failover chain for an agent: its model followed by that model's `fallbacks`
  (resolved, deduped, missing names dropped). Transient errors walk down the chain.
  """
  def model_chain_for_agent(%Agent{} = agent) do
    case model_for_agent(agent) do
      nil ->
        []

      primary ->
        fallbacks =
          primary.fallbacks
          |> Enum.map(&get_model/1)
          |> Enum.reject(&is_nil/1)

        Enum.uniq_by([primary | fallbacks], & &1.name)
    end
  end

  ###
  ### Scheduled tasks (crons)
  ###

  @doc "All configured crons, as `Cortex.Config.Cron` structs."
  def crons do
    load()
    |> Map.get("crons", %{})
    |> Enum.map(fn {id, map} -> Cron.from_map(Map.put(map, "id", id)) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Fetch one cron by id, or nil."
  def get_cron(id) do
    case load() |> get_in(["crons", id]) do
      nil -> nil
      map -> Cron.from_map(Map.put(map, "id", id))
    end
  end

  @doc "Create or replace a cron (keyed by its `id`)."
  def put_cron(%Cron{id: id} = cron) when is_binary(id) do
    map = cron |> Map.from_struct() |> Map.delete(:id) |> stringify()

    load()
    |> update_in(["crons"], fn c -> Map.put(c || %{}, id, map) end)
    |> save()
  end

  @doc "Delete a cron by id."
  def delete_cron(id) do
    load()
    |> update_in(["crons"], &Map.delete(&1 || %{}, id))
    |> save()
  end

  ###
  ### Gateways
  ###

  def telegram do
    load() |> Map.get("telegram", %{})
  end

  def put_telegram(map) when is_map(map) do
    load() |> Map.put("telegram", map) |> save()
  end

  @doc """
  All configured Telegram bots as maps, each carrying a `"name"`. Multi-channel:
  the legacy singular `"telegram"` map is the bot named `"default"`; any extra bots
  live under `"telegrams"` (a name→config map), each bound to its own agent. Bots
  that resolve to the same token are de-duplicated (two pollers on one token would
  409 against each other).
  """
  def telegram_bots do
    base =
      case load()["telegram"] do
        m when is_map(m) and map_size(m) > 0 -> [Map.put(m, "name", m["name"] || "default")]
        _ -> []
      end

    extra =
      load()
      |> Map.get("telegrams", %{})
      |> Enum.map(fn {name, m} -> Map.put(m, "name", name) end)
      |> Enum.sort_by(& &1["name"])

    (base ++ extra)
    |> Enum.uniq_by(fn m -> interpolate(m["bot_token"]) || m["name"] end)
  end

  @doc "Fetch one Telegram bot config by name (`\"default\"` is the legacy one)."
  def telegram_bot(name), do: Enum.find(telegram_bots(), &(&1["name"] == name))

  @doc "Create or replace a named (non-default) Telegram bot."
  def put_telegram_bot(name, map) when is_binary(name) and is_map(map) do
    clean = Map.delete(map, "name")

    load()
    |> update_in(["telegrams"], fn t -> Map.put(t || %{}, name, clean) end)
    |> save()
  end

  @doc "Delete a named Telegram bot."
  def delete_telegram_bot(name) do
    load()
    |> update_in(["telegrams"], &Map.delete(&1 || %{}, name))
    |> save()
  end

  ###
  ### MCP servers (Model Context Protocol)
  ###

  @doc """
  Configured MCP servers as `%{name => %{command, args, env}}`. Each is an external
  tool server launched over stdio (e.g. `npx @sentry/mcp-server`). Secrets go in
  `args`/`env` as `${ENV_VAR}` references, resolved at spawn time.
  """
  def mcp_servers, do: load() |> Map.get("mcp", %{})

  @doc "One MCP server spec by name, as an atom-keyed map ready for Cortex.MCP.Client, or nil."
  def mcp_server(name) do
    case mcp_servers()[name] do
      nil ->
        nil

      map ->
        %{
          command: map["command"],
          args: map["args"] || [],
          env: map["env"] || %{}
        }
    end
  end

  @doc "Create or replace an MCP server definition."
  def put_mcp_server(name, map) when is_binary(name) and is_map(map) do
    load()
    |> update_in(["mcp"], fn m -> Map.put(m || %{}, name, map) end)
    |> save()
  end

  @doc "Delete an MCP server definition."
  def delete_mcp_server(name) do
    load()
    |> update_in(["mcp"], &Map.delete(&1 || %{}, name))
    |> save()
  end

  def server do
    load() |> Map.get("server", %{"port" => 4000})
  end

  @doc """
  Default IANA timezone for scheduled tasks that don't name their own (e.g.
  `"America/Sao_Paulo"`). Set at `mix cortex setup`; falls back to UTC.
  """
  def default_timezone, do: load()["timezone"] || "Etc/UTC"

  @doc "Set the default timezone for scheduled tasks."
  def set_default_timezone(tz), do: load() |> Map.put("timezone", tz) |> save()

  @doc "Locale for fixed system messages (default \"en\")."
  def locale, do: load()["locale"] || "en"

  @doc "Set the locale and apply it to Gettext for this process."
  def set_locale(locale) do
    load() |> Map.put("locale", locale) |> save()
  end

  @doc "Apply the configured locale to `Cortex.Gettext` (call per process)."
  def put_locale, do: Gettext.put_locale(Cortex.Gettext, locale())

  ###
  ### Helpers
  ###

  @doc """
  Interpolate `${ENV_VAR}` references in a string against the environment.
  Non-strings pass through untouched. A bare `${VAR}` resolving to nothing
  returns nil so callers can treat it as "unset".
  """
  def interpolate(nil), do: nil

  def interpolate(value) when is_binary(value) do
    cond do
      # whole-string single placeholder -> nil when env missing
      Regex.match?(~r/^\$\{[A-Z0-9_]+\}$/, value) ->
        var = String.slice(value, 2..-2//1)
        System.get_env(var)

      String.contains?(value, "${") ->
        Regex.replace(~r/\$\{([A-Z0-9_]+)\}/, value, fn _, var ->
          System.get_env(var) || ""
        end)

      true ->
        value
    end
  end

  def interpolate(value), do: value

  defp encode(struct) do
    struct |> Map.from_struct() |> Map.delete(:name) |> stringify()
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_default(config, key, name) do
    if is_nil(config[key]), do: Map.put(config, key, name), else: config
  end

  defp clear_default_if(config, key, name) do
    if config[key] == name, do: Map.put(config, key, nil), else: config
  end
end
