defmodule Pepe.Migrate.Openclaw do
  @moduledoc """
  Read an openclaw state directory (`~/.openclaw` by default, `openclaw.json`) and produce
  a migration plan for `Pepe.Migrate`: its model providers become Pepe model connections,
  its agents become Pepe agents (persona from the workspace markdown), and a Telegram bot
  token is carried over. Tools and other channels are reported, not mapped, since their
  ids have no direct Pepe equivalent.
  """

  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Migrate

  # A conservative default toolset for a migrated agent (the source tool ids do not map).
  @default_tools ~w(bash read_file write_file edit_file list_dir fetch_url web_search)

  def default_home do
    System.get_env("OPENCLAW_STATE_DIR") || Path.join(home_root(), ".openclaw")
  end

  defp home_root, do: System.get_env("OPENCLAW_HOME") || System.user_home!()

  def plan(home) do
    case read_config(home) do
      {:ok, config} ->
        models(config) ++ agents(config, home) ++ channels(config) ++ skills(config, home)

      {:error, reason} ->
        [%{kind: :skip, what: "config", reason: "could not read openclaw.json (#{reason})"}]
    end
  end

  defp read_config(home) do
    path = Enum.find([Path.join(home, "openclaw.json"), Path.join(home, "clawdbot.json")], &File.exists?/1)

    with true <- is_binary(path),
         {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(strip_comments(body)) do
      {:ok, config}
    else
      false -> {:error, "not found"}
      {:error, %Jason.DecodeError{}} -> {:error, "invalid JSON"}
      _ -> {:error, "unreadable"}
    end
  end

  # openclaw.json allows JSON5-style comments; drop them so Jason can parse.
  defp strip_comments(body) do
    body
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.replace(~r{(^|\s)//[^\n]*}, "\\1")
  end

  # --- models -----------------------------------------------------------------------

  defp models(config) do
    providers = get_in(config, ["models", "providers"]) || %{}

    Enum.flat_map(providers, fn {provider_id, pconf} ->
      base = pconf["baseUrl"]
      {key, note} = Migrate.secret(pconf["apiKey"])

      case pconf["models"] || [] do
        [] ->
          [%{kind: :skip, what: "provider #{provider_id}", reason: "no models listed"}]

        list ->
          Enum.map(list, &model_action(&1, provider_id, base, key, note))
      end
    end)
  end

  defp model_action(m, provider_id, base, key, note) do
    model = %Model{
      name: "#{provider_id}/#{m["id"]}",
      base_url: base,
      api_key: key,
      model: m["id"],
      api: "openai-completions",
      context_window: m["contextWindow"],
      max_tokens: m["maxTokens"]
    }

    action = %{kind: :model, model: model}
    if note, do: Map.put(action, :note, note), else: action
  end

  # --- agents -----------------------------------------------------------------------

  defp agents(config, home) do
    list = get_in(config, ["agents", "list"]) || []
    workspace = agent_workspace(config, home)

    Enum.map(list, fn a ->
      name = a["id"] || a["name"]
      persona = Migrate.read(Path.join(workspace, "AGENTS.md")) || Migrate.read(Path.join(workspace, "SOUL.md"))
      memory = Migrate.read(Path.join(workspace, "MEMORY.md")) || Migrate.read(Path.join(workspace, "memory.md"))

      base = %Agent{
        name: name,
        model: agent_model(a["model"]),
        tools: Migrate.map_tools(agent_tools(a["tools"]), @default_tools),
        temperature: get_in(a, ["params", "temperature"])
      }

      agent = if persona, do: %{base | system_prompt: persona}, else: base
      %{kind: :agent, agent: agent, files: [{"MEMORY.md", memory}]}
    end)
  end

  # `AgentToolsConfig` may be a plain list of ids or a map with an "allow" list.
  defp agent_tools(tools) when is_list(tools), do: tools
  defp agent_tools(%{"allow" => allow}) when is_list(allow), do: allow
  defp agent_tools(_), do: []

  defp agent_workspace(config, home) do
    get_in(config, ["agents", "defaults", "workspace"]) ||
      System.get_env("OPENCLAW_WORKSPACE_DIR") ||
      Path.join(home, "workspace")
  end

  # `"provider/model"` or `%{"primary" => "provider/model"}` -> the Pepe model name.
  defp agent_model(model) when is_binary(model), do: model
  defp agent_model(%{"primary" => primary}) when is_binary(primary), do: primary
  defp agent_model(_), do: nil

  # --- channels ---------------------------------------------------------------------

  defp channels(config) do
    channels = config["channels"] || %{}
    telegram(channels) ++ slack(channels) ++ msteams(channels) ++ leftover(channels)
  end

  defp telegram(channels) do
    case get_in(channels, ["telegram", "botToken"]) do
      token when is_binary(token) and token != "" ->
        [%{kind: :telegram, token: token, allowed_chats: get_in(channels, ["telegram", "allowFrom"])}]

      _ ->
        []
    end
  end

  defp slack(channels) do
    case get_in(channels, ["slack", "botToken"]) do
      token when is_binary(token) and token != "" ->
        cfg = drop_nil(%{"bot_token" => token, "signing_secret" => get_in(channels, ["slack", "signingSecret"])})
        [webhook("slack", cfg)]

      _ ->
        []
    end
  end

  defp msteams(channels) do
    case get_in(channels, ["msteams", "appId"]) do
      app_id when is_binary(app_id) and app_id != "" ->
        cfg =
          drop_nil(%{
            "app_id" => app_id,
            "app_password" => get_in(channels, ["msteams", "appPassword"]),
            "tenant_id" => get_in(channels, ["msteams", "tenant"])
          })

        [webhook("msteams", cfg)]

      _ ->
        []
    end
  end

  # Discord (gateway token, not the interactions model) and Google Chat (service account)
  # do not fit Pepe's webhook credentials, so they are reported for a fresh setup.
  defp leftover(channels) do
    channels
    |> Map.drop(["telegram", "slack", "msteams"])
    |> Enum.filter(fn {_k, v} -> is_map(v) and v["enabled"] == true end)
    |> Enum.map(fn {k, _v} -> %{kind: :skip, what: "channel #{k}", reason: "set it up in Integrations (credentials differ)"} end)
  end

  defp webhook(provider, config) do
    %{kind: :webhook, slug: provider, entry: %{"provider" => provider, "agent" => "assistant", "mode" => "support", "config" => config}}
  end

  defp drop_nil(map), do: for({k, v} <- map, not is_nil(v), into: %{}, do: {k, v})

  # --- skills -----------------------------------------------------------------------

  defp skills(config, home) do
    dirs = [Path.join(agent_workspace(config, home), "skills"), Path.join(home, "plugin-skills")]

    dirs
    |> Enum.flat_map(&Migrate.skills_in/1)
    |> Enum.uniq_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, content} -> %{kind: :skill, name: name, content: content} end)
  end
end
