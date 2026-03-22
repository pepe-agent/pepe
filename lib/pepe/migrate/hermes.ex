defmodule Pepe.Migrate.Hermes do
  @moduledoc """
  Read a hermes home (`~/.hermes` by default, `config.yaml` + `.env`) and produce a
  migration plan for `Pepe.Migrate`: its model and custom providers become Pepe model
  connections, its persona (`SOUL.md`) and named personalities become Pepe agents, and a
  Telegram bot token from `.env` is carried over. Tools and other platforms are reported,
  not mapped.
  """

  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Migrate

  @default_tools ~w(bash read_file write_file edit_file list_dir fetch_url web_search)

  def default_home do
    System.get_env("HERMES_HOME") || Path.join(System.user_home!(), ".hermes")
  end

  def plan(home) do
    case read_config(home) do
      {:ok, config} ->
        env = read_env(home)

        models(config, env) ++
          agents(config, home) ++ channels(config, env) ++ skills(home)

      {:error, reason} ->
        [%{kind: :skip, what: "config", reason: "could not read config.yaml (#{reason})"}]
    end
  end

  defp read_config(home) do
    path = Path.join(home, "config.yaml")

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, config} when is_map(config) -> {:ok, config}
        _ -> {:error, "invalid YAML"}
      end
    else
      {:error, "not found"}
    end
  end

  # Parse `.env` into a plain map (KEY=value, ignoring blanks and comments).
  defp read_env(home) do
    case File.read(Path.join(home, ".env")) do
      {:ok, body} ->
        for line <- String.split(body, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            [k, v] <- [String.split(line, "=", parts: 2)],
            into: %{},
            do: {String.trim(k), v |> String.trim() |> String.trim(~s("))}

      _ ->
        %{}
    end
  end

  # --- models -----------------------------------------------------------------------

  defp models(config, env) do
    global = global_model(config, env)
    providers = named_providers(config)
    Enum.reject([global | providers], &is_nil/1)
  end

  defp global_model(config, env) do
    m = config["model"] || %{}
    model_id = m["default"] || m["model"]

    if is_binary(model_id) and model_id != "" do
      %{
        kind: :model,
        model: %Model{
          name: m["provider"] || "hermes",
          base_url: m["base_url"] || "https://openrouter.ai/api/v1",
          api_key: m["api_key"] || env_key(env, m["provider"]),
          model: model_id,
          api: "openai-completions",
          context_window: m["context_length"],
          max_tokens: m["max_tokens"]
        }
      }
    end
  end

  defp named_providers(config) do
    providers = config["providers"] || %{}

    Enum.map(providers, fn {name, p} ->
      {key, _note} = Migrate.secret(provider_key(p))

      %{
        kind: :model,
        model: %Model{
          name: name,
          base_url: p["base_url"] || p["url"] || p["api"],
          api_key: key,
          model: p["model"] || p["default_model"],
          api: "openai-completions",
          context_window: p["context_length"]
        }
      }
    end)
  end

  defp provider_key(p) do
    cond do
      is_binary(p["key_env"]) -> "${#{p["key_env"]}}"
      is_binary(p["api_key_env"]) -> "${#{p["api_key_env"]}}"
      is_binary(p["api_key"]) -> p["api_key"]
      true -> nil
    end
  end

  defp env_key(env, "anthropic"), do: ref_or_nil(env, "ANTHROPIC_API_KEY")
  defp env_key(env, "openrouter"), do: ref_or_nil(env, "OPENROUTER_API_KEY")
  defp env_key(env, "openai"), do: ref_or_nil(env, "OPENAI_API_KEY")
  defp env_key(_env, _), do: nil

  defp ref_or_nil(env, key), do: if(Map.has_key?(env, key), do: "${#{key}}", else: nil)

  # --- agents -----------------------------------------------------------------------

  defp agents(config, home) do
    model_name = default_model_name(config)
    memory = Migrate.read(Path.join(home, "MEMORY.md"))
    user = Migrate.read(Path.join(home, "USER.md"))
    files = Enum.reject([{"MEMORY.md", memory}, {"USER.md", user}], fn {_, c} -> is_nil(c) end)

    main =
      case Migrate.read(Path.join(home, "SOUL.md")) do
        nil -> []
        soul -> [agent("assistant", soul, model_name, files)]
      end

    personalities =
      config
      |> get_in(["agent", "personalities"])
      |> case do
        map when is_map(map) -> Enum.map(map, fn {name, prompt} -> agent(name, to_string(prompt), model_name, []) end)
        _ -> []
      end

    main ++ personalities ++ profiles(home, model_name)
  end

  # Each profiles/<name>/ is a full home; carry its persona over as its own agent.
  defp profiles(home, model_name) do
    dir = Path.join(home, "profiles")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.map(fn name ->
          soul = Migrate.read(Path.join([dir, name, "SOUL.md"]))
          memory = Migrate.read(Path.join([dir, name, "MEMORY.md"]))
          files = if memory, do: [{"MEMORY.md", memory}], else: []
          agent(name, soul, model_name, files)
        end)

      _ ->
        []
    end
  end

  defp agent(name, prompt, model_name, files) do
    base = %Agent{name: name, model: model_name, tools: @default_tools}
    agent = if prompt in [nil, ""], do: base, else: %{base | system_prompt: prompt}
    %{kind: :agent, agent: agent, files: files}
  end

  defp default_model_name(config) do
    get_in(config, ["model", "provider"]) || "hermes"
  end

  # --- channels ---------------------------------------------------------------------

  defp channels(config, env) do
    platforms = Map.get(config, "platforms", %{})
    telegram(platforms, env) ++ whatsapp(platforms) ++ other_platforms(platforms)
  end

  defp telegram(platforms, env) do
    case env["TELEGRAM_BOT_TOKEN"] || get_in(platforms, ["telegram", "token"]) do
      token when is_binary(token) and token != "" ->
        [%{kind: :telegram, token: token, allowed_chats: get_in(platforms, ["telegram", "allowed_chats"])}]

      _ ->
        []
    end
  end

  defp whatsapp(platforms) do
    extra = get_in(platforms, ["whatsapp", "extra"]) || %{}

    if is_binary(extra["phone_number_id"]) and is_binary(extra["access_token"]) do
      entry = %{
        "provider" => "whatsapp",
        "agent" => "assistant",
        "mode" => "support",
        "config" => %{
          "phone_number_id" => extra["phone_number_id"],
          "access_token" => extra["access_token"]
        }
      }

      [%{kind: :webhook, slug: "whatsapp", entry: entry}]
    else
      []
    end
  end

  defp other_platforms(platforms) do
    platforms
    |> Map.drop(["telegram", "whatsapp"])
    |> Enum.filter(fn {_k, v} -> is_map(v) and v["enabled"] == true end)
    |> Enum.map(fn {k, _v} -> %{kind: :skip, what: "platform #{k}", reason: "set it up in Channels/Integrations"} end)
  end

  # --- skills -----------------------------------------------------------------------

  defp skills(home) do
    Path.join(home, "skills")
    |> Migrate.skills_in()
    |> Enum.map(fn {name, content} -> %{kind: :skill, name: name, content: content} end)
  end
end
