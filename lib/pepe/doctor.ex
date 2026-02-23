defmodule Pepe.Doctor do
  @moduledoc """
  Health checks for the whole setup - the **verify** half of do -> verify -> correct.

  Run after changing something (or any time) to catch what's broken *before* it
  bites: unset `${ENV}` secrets, agents pointing at missing models, unknown tools in
  an allowlist, invalid cron schedules/timezones, unreachable Telegram bots and MCP
  servers.

  Two tiers so it's cheap by default:

    * `checks/0` - offline checks only (config consistency). Fast, no network.
    * `checks/1` with `live: true` - also probes the outside world: Telegram `getMe`
      per bot, a `/models` ping per model connection, and an MCP launch + tools list
      per server.

  Each check is `{area, subject, :ok | {:warn, msg} | {:error, msg}}`.
  """

  alias Pepe.Config

  @type status :: :ok | {:warn, String.t()} | {:error, String.t()}
  @type check :: {String.t(), String.t(), status()}

  @spec checks(keyword()) :: [check()]
  def checks(opts \\ []) do
    offline = env_checks() ++ agent_checks() ++ cron_checks()

    if opts[:live] do
      offline ++ telegram_checks() ++ model_checks() ++ mcp_checks()
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

      [model_check | tools_check]
    end)
  end

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

  ###
  ### live checks (network)
  ###

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
          case Req.get("https://api.telegram.org/bot#{token}/getMe", receive_timeout: 10_000) do
            {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"username" => u}}}} ->
              {"telegram", name, {:warn, "ok (@#{u})"} |> ok_if_ok()}

            {:ok, %{status: 401}} ->
              {"telegram", name, {:error, "invalid token (401)"}}

            other ->
              {"telegram", name, {:error, "unreachable: #{describe(other)}"}}
          end
      end
    end)
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
