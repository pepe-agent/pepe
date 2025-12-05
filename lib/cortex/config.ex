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

  ###
  ### Gateways
  ###

  def telegram do
    load() |> Map.get("telegram", %{})
  end

  def put_telegram(map) when is_map(map) do
    load() |> Map.put("telegram", map) |> save()
  end

  def server do
    load() |> Map.get("server", %{"port" => 4000})
  end

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
