defmodule Pepe.Config do
  @moduledoc """
  File-backed configuration store, the single source of truth for model
  connections, agents and gateway credentials.

  Lives at `~/.pepe/config.json` by default. Override the directory with the
  `PEPE_HOME` env var, or point straight at a file with `PEPE_CONFIG`.

  The on-disk shape:

      {
        "default_model": "openrouter",
        "models": { "openrouter": { ...Pepe.Config.Model } },
        "default_agent": "assistant",
        "agents": { "assistant": { ...Pepe.Config.Agent } },
        "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [] },
        "server": { "port": 4000 }
      }

  Secrets may be written literally or as `${ENV_VAR}` placeholders; they are
  interpolated against the environment at read time, never persisted expanded.
  """

  alias Pepe.Company
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Config.Model

  @doc "Absolute path to the config directory (created on demand)."
  def home do
    System.get_env("PEPE_HOME") || Path.join(System.user_home!(), ".pepe")
  end

  @doc "Absolute path to the config file."
  def path do
    System.get_env("PEPE_CONFIG") || Path.join(home(), "config.json")
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
    |> maybe_default_root("default_model", name)
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

  @doc "Set the default model for a scope: global for root, or the company's own."
  def set_default_model_for(nil, name), do: set_default_model(name)

  def set_default_model_for(company, name) do
    load()
    |> update_in(["companies", company], fn m -> Map.put(m || %{}, "default_model", name) end)
    |> save()
  end

  ###
  ### Companies (multi-tenant scopes)
  ###

  @doc """
  Names of all configured companies (the tenant scopes), sorted. The **root** scope
  is not a company — it's the implicit default every command uses without
  `--company`, so it never appears here.
  """
  def companies do
    load() |> Map.get("companies", %{}) |> Map.keys() |> Enum.sort()
  end

  @doc "Fetch one company's metadata map by name, or nil."
  def get_company(name), do: load() |> get_in(["companies", name])

  @doc "Does this company exist?"
  def company_exists?(name), do: not is_nil(get_company(name))

  @doc """
  Create a company (a tenant scope). Fails on an invalid name or a duplicate. Meta
  is a free-form map (e.g. `%{\"description\" => ...}`); a `\"created\"` marker is kept.
  """
  def add_company(name, meta \\ %{}) do
    cond do
      not Company.valid_name?(name) ->
        {:error, :invalid_name}

      company_exists?(name) ->
        {:error, :already_exists}

      true ->
        load()
        |> update_in(["companies"], fn c ->
          Map.put(c || %{}, name, Map.put_new(meta, "created", true))
        end)
        |> save()

        :ok
    end
  end

  @doc """
  Update a company's metadata (e.g. its `"description"`). Merges `meta` over the
  existing map, dropping keys whose value is nil, and always keeps the `"created"`
  marker. The name is the identity key and never changes here. Fails if unknown.
  """
  def update_company(name, meta) do
    case get_company(name) do
      nil ->
        {:error, :not_found}

      existing ->
        merged =
          existing
          |> Map.merge(meta)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
          |> Map.put("created", true)

        load()
        |> update_in(["companies"], &Map.put(&1 || %{}, name, merged))
        |> save()

        :ok
    end
  end

  @doc """
  Delete a company. Refuses while it still owns agents unless `force: true`, which
  also drops those agents from the config (their workspace files are left on disk).
  """
  def delete_company(name, opts \\ []) do
    owned = agents_in(name)

    cond do
      not company_exists?(name) ->
        {:error, :not_found}

      owned != [] and not Keyword.get(opts, :force, false) ->
        {:error, {:not_empty, length(owned)}}

      true ->
        config = load()
        agents = Map.get(config, "agents", %{})
        kept = Map.reject(agents, fn {handle, _} -> Company.of(handle) == name end)

        config
        |> Map.put("agents", kept)
        |> update_in(["companies"], &Map.delete(&1 || %{}, name))
        |> save()

        :ok
    end
  end

  @doc """
  Rename a company, re-keying everything that carries its handle: the company entry
  itself, its agents and models (and any `company/…` references in `can_message` /
  `can_manage`), and the `agent` binding of every cron, watch, bot and API token
  that points at one of its agents. Also moves the company's workspace and usage
  directories on disk. Free text (prompts, descriptions) is never touched.

  Fails on an invalid or already-taken new name, or an unknown old one. Best done
  while idle: any in-flight session keyed by an old handle simply finishes; new
  requests use the new handle.
  """
  def rename_company(old, new) do
    cond do
      not Company.valid_name?(new) -> {:error, :invalid_name}
      not company_exists?(old) -> {:error, :not_found}
      old == new -> :ok
      company_exists?(new) -> {:error, :already_exists}
      true -> do_rename_company(old, new)
    end
  end

  defp do_rename_company(old, new) do
    load()
    |> rename_company_entry(old, new)
    |> rekey_section("agents", old, new, &rewrite_agent_refs(&1, old, new))
    |> rekey_section("models", old, new, & &1)
    |> rewrite_agent_binding("crons", old, new)
    |> rewrite_agent_binding("watches", old, new)
    |> rewrite_bot_bindings(old, new)
    |> rewrite_token_scopes(old, new)
    |> remap_field("default_agent", old, new)
    |> remap_field("default_model", old, new)
    |> save()

    move_company_dirs(old, new)
    :ok
  end

  # A handle in `old`'s scope becomes the same name in `new`; the bare company name
  # (e.g. a token's `"company"`) is remapped too. Anything else is left alone.
  defp remap_handle(h, old, new) when is_binary(h) do
    cond do
      h == old -> new
      Company.of(h) == old -> Company.handle(new, Company.name_of(h))
      true -> h
    end
  end

  defp remap_handle(h, _old, _new), do: h

  defp rename_company_entry(config, old, new) do
    update_in(config, ["companies"], fn cs ->
      {meta, rest} = Map.pop(cs || %{}, old)
      Map.put(rest, new, meta || %{})
    end)
  end

  # Re-key a handle-keyed map (agents/models): rename `old/…` keys and transform the
  # value with `tx`.
  defp rekey_section(config, section, old, new, tx) do
    case Map.get(config, section) do
      m when is_map(m) ->
        Map.put(config, section, Map.new(m, fn {k, v} -> {remap_handle(k, old, new), tx.(v)} end))

      _ ->
        config
    end
  end

  defp rewrite_agent_refs(agent, old, new) when is_map(agent) do
    agent
    |> remap_list("can_message", old, new)
    |> remap_list("can_manage", old, new)
  end

  defp rewrite_agent_refs(agent, _old, _new), do: agent

  defp remap_list(map, field, old, new) do
    case Map.get(map, field) do
      list when is_list(list) -> Map.put(map, field, Enum.map(list, &remap_handle(&1, old, new)))
      _ -> map
    end
  end

  # In an id→entry map (crons/watches), remap each entry's `"agent"` handle.
  defp rewrite_agent_binding(config, section, old, new) do
    case Map.get(config, section) do
      m when is_map(m) ->
        Map.put(
          config,
          section,
          Map.new(m, fn {id, v} -> {id, remap_field(v, "agent", old, new)} end)
        )

      _ ->
        config
    end
  end

  defp rewrite_bot_bindings(config, old, new) do
    config
    |> remap_field_in("telegram", "agent", old, new)
    |> rewrite_agent_binding("telegrams", old, new)
  end

  defp rewrite_token_scopes(config, old, new) do
    case Map.get(config, "api_tokens") do
      m when is_map(m) ->
        Map.put(
          config,
          "api_tokens",
          Map.new(m, fn {id, e} ->
            {id, e |> remap_field("company", old, new) |> remap_field("agent", old, new)}
          end)
        )

      _ ->
        config
    end
  end

  # Remap `map[field]` when it's a handle string; leave the map untouched otherwise.
  defp remap_field(map, field, old, new) when is_map(map) do
    case Map.get(map, field) do
      h when is_binary(h) -> Map.put(map, field, remap_handle(h, old, new))
      _ -> map
    end
  end

  defp remap_field(map, _field, _old, _new), do: map

  # Same, but for a nested map at `config[section]`.
  defp remap_field_in(config, section, field, old, new) do
    case Map.get(config, section) do
      m when is_map(m) -> Map.put(config, section, remap_field(m, field, old, new))
      _ -> config
    end
  end

  defp move_company_dirs(old, new) do
    for base <- [Path.join(home(), "companies"), Path.join([home(), "data", "usage"])] do
      src = Path.join(base, old)
      dst = Path.join(base, new)
      if File.dir?(src) and not File.exists?(dst), do: File.rename(src, dst)
    end

    :ok
  end

  @doc """
  Agents in a scope: `nil` for the root scope, or a company name. Root returns only
  bare-name agents; a company returns only its own — never another's.
  """
  def agents_in(scope) do
    agents() |> Enum.filter(fn a -> Company.of(a.name) == scope end)
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
    |> maybe_default_root("default_agent", name)
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
  Set the default agent for a scope: the global default for root, or the company's
  own default (stored as a bare name in the company meta) for a company.
  """
  def set_default_agent_for(nil, name), do: set_default_agent(name)

  def set_default_agent_for(company, name) do
    load()
    |> update_in(["companies", company], fn m -> Map.put(m || %{}, "default_agent", name) end)
    |> save()
  end

  @doc """
  The default model for a scope: a company's own default if it pins one (resolved in
  the company then the root scope), otherwise the root default. So companies can
  share the operator's global provider or pin their own isolated keys.
  """
  def default_model_for(nil), do: default_model()

  def default_model_for(company) do
    case (get_company(company) || %{})["default_model"] do
      nil -> default_model()
      ref -> get_model(Company.handle(company, ref)) || get_model(ref) || default_model()
    end
  end

  @doc "The default agent handle for a scope, or nil. Root uses the global default."
  def default_agent_for(nil), do: default_agent_name()

  def default_agent_for(company) do
    case (get_company(company) || %{})["default_agent"] do
      nil -> nil
      name -> Company.handle(company, name)
    end
  end

  @doc """
  Resolve the model connection an agent should use. A company agent's model
  reference resolves within its own company first, then the root scope; an unset
  reference falls back to the scope's default model. Company keys stay invisible to
  other companies.
  """
  def model_for_agent(%Agent{name: handle, model: nil}), do: default_model_for(Company.of(handle))

  def model_for_agent(%Agent{name: handle, model: ref}) do
    scope = Company.of(handle)
    get_model(Company.handle(scope, ref)) || get_model(ref) || default_model_for(scope)
  end

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

  @doc "All configured crons, as `Pepe.Config.Cron` structs."
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
  ### Watches (one-shot "notify me when X" commitments)
  ###

  alias Pepe.Config.Watch

  @doc "All watches, as `Pepe.Config.Watch` structs, sorted by id."
  def watches do
    load()
    |> Map.get("watches", %{})
    |> Enum.map(fn {id, map} -> Watch.from_map(Map.put(map, "id", id)) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Fetch one watch by id, or nil."
  def get_watch(id) do
    case load() |> get_in(["watches", id]) do
      nil -> nil
      map -> Watch.from_map(Map.put(map, "id", id))
    end
  end

  @doc "Create or replace a watch (keyed by its `id`)."
  def put_watch(%Watch{id: id} = watch) when is_binary(id) do
    map = watch |> Map.from_struct() |> Map.delete(:id) |> stringify()

    load()
    |> update_in(["watches"], fn w -> Map.put(w || %{}, id, map) end)
    |> save()
  end

  @doc "Delete a watch by id."
  def delete_watch(id) do
    load()
    |> update_in(["watches"], &Map.delete(&1 || %{}, id))
    |> save()
  end

  ###
  ### API access tokens
  ###

  @doc """
  All API tokens as maps (each carrying its `"id"`), sorted by id. Only the hash is
  stored — never the raw token.
  """
  def api_tokens do
    load()
    |> Map.get("api_tokens", %{})
    |> Enum.map(fn {id, m} -> Map.put(m, "id", id) end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Is API auth on? It turns on the moment the first token exists — with none, the
  `/v1` API stays open (single-tenant/backward-compatible). Creating a token locks it.
  """
  def api_auth_required?, do: api_tokens() != []

  @doc """
  Mint an API token scoped to `company` (nil = root) and optionally `agent` (a full
  handle). Returns `{raw_token, id}`; the raw token is shown once and only its hash is
  stored. `agent` must be within `company`.
  """
  def add_api_token(opts \\ []) do
    company = opts[:company]
    agent = opts[:agent]

    cond do
      company && not company_exists?(company) ->
        {:error, :unknown_company}

      agent && Company.of(agent) != company ->
        {:error, :agent_out_of_scope}

      agent && is_nil(get_agent(agent)) ->
        {:error, :unknown_agent}

      true ->
        raw = Pepe.ApiToken.generate()
        id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

        entry = %{
          "hash" => Pepe.ApiToken.hash(raw),
          "company" => company,
          "agent" => agent,
          "label" => opts[:label],
          "prefix" => Pepe.ApiToken.fingerprint(raw)
        }

        load()
        |> update_in(["api_tokens"], fn t -> Map.put(t || %{}, id, entry) end)
        |> save()

        {:ok, raw, id}
    end
  end

  @doc "Revoke a token by id."
  def revoke_api_token(id) do
    if get_in(load(), ["api_tokens", id]) do
      load() |> update_in(["api_tokens"], &Map.delete(&1 || %{}, id)) |> save()
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Verify a raw bearer token. Returns its scope `%{company: c, agent: a}` (either may
  be nil) when it matches a stored hash, or `nil` when it doesn't.
  """
  def verify_api_token(raw) when is_binary(raw) do
    hash = Pepe.ApiToken.hash(raw)

    case Enum.find(api_tokens(), &(&1["hash"] == hash)) do
      nil -> nil
      t -> %{company: t["company"], agent: t["agent"]}
    end
  end

  def verify_api_token(_), do: nil

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

  @doc "One MCP server spec by name, as an atom-keyed map ready for Pepe.MCP.Client, or nil."
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
  `"America/Sao_Paulo"`). Set at `mix pepe setup`; falls back to UTC.
  """
  def default_timezone, do: load()["timezone"] || "Etc/UTC"

  @doc "Set the default timezone for scheduled tasks."
  def set_default_timezone(tz), do: load() |> Map.put("timezone", tz) |> save()

  @doc """
  The billing currency symbol/code used to label costs (default `\"USD\"`). Prices
  are entered and shown in this currency; there is no FX conversion.
  """
  def currency, do: load()["currency"] || "USD"

  @doc "Set the billing currency label."
  def set_currency(code), do: load() |> Map.put("currency", code) |> save()

  @doc """
  A company's billing markup: the multiplier applied to provider cost to get the
  amount to charge. Unset (or root) means `1.0` — bill exactly the provider cost.
  """
  @spec company_markup(String.t() | nil) :: float()
  def company_markup(nil), do: 1.0

  def company_markup(company) do
    case (get_company(company) || %{})["markup"] do
      n when is_number(n) and n > 0 -> n / 1
      _ -> 1.0
    end
  end

  @doc "Locale for fixed system messages (default \"en\")."
  def locale, do: load()["locale"] || "en"

  @doc "Set the locale and apply it to Gettext for this process."
  def set_locale(locale) do
    load() |> Map.put("locale", locale) |> save()
  end

  @doc "Apply the configured locale to `Pepe.Gettext` (call per process)."
  def put_locale, do: Gettext.put_locale(Pepe.Gettext, locale())

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

  # Like maybe_default/3 but only for root-scope handles: a company agent/model must
  # never become the global (root) default just by being the first one created.
  defp maybe_default_root(config, key, name) do
    if is_nil(Company.of(name)), do: maybe_default(config, key, name), else: config
  end

  defp clear_default_if(config, key, name) do
    if config[key] == name, do: Map.put(config, key, nil), else: config
  end
end
