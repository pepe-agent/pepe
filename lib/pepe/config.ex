defmodule Pepe.Config do
  @moduledoc """
  File-backed configuration store, the single source of truth for model
  connections, agents and gateway credentials.

  Lives at `~/.pepe/config.json` by default. Override the directory with the
  `PEPE_HOME` env var, or point straight at a file with `PEPE_CONFIG`.

  The on-disk shape:

      {
        "default_model": "a1b2c3d4",
        "models": { "a1b2c3d4": { "name": "openrouter", ...Pepe.Config.Model } },
        "default_agent": "assistant",
        "agents": { "assistant": { "model": "a1b2c3d4", ...Pepe.Config.Agent } },
        "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [] },
        "server": { "port": 4000 }
      }

  Model connections are the one thing keyed by a stable id rather than by name:
  `name` is a free-form, renamable display label, while every reference to a
  model (`default_model`, an agent's/cron's `model`) stores the id, so renaming
  a connection never requires touching anything that points at it. Reading a
  model back through this module (`get_model/1`, an agent's/cron's `.model`
  field) always resolves the id to whatever name is current, so callers never
  see a raw id. See `rename_model/2`.

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

  @doc """
  Shorten an absolute path for display: the Pepe home becomes `~/.pepe` (or `$PEPE_HOME`
  when that override is set), and the user's home becomes `~`. Keeps diagnostic and setup
  output readable instead of printing long absolute paths.
  """
  def short_path(path) do
    path = to_string(path)
    home = home()
    user = user_home()

    cond do
      String.starts_with?(path, home) ->
        marker = if System.get_env("PEPE_HOME"), do: "$PEPE_HOME", else: "~/.pepe"
        marker <> String.replace_prefix(path, home, "")

      user && String.starts_with?(path, user) ->
        "~" <> String.replace_prefix(path, user, "")

      true ->
        path
    end
  end

  defp user_home, do: System.user_home()

  @backups_kept 5

  @doc """
  Copy the current config file to a timestamped `.bak.<unix>` alongside it, keeping only
  the last few, and return the backup path (or `nil` when there's no config yet). A cheap
  safety net to call before a mutating operation (setup) or an upgrade.
  """
  def backup do
    p = path()

    if File.regular?(p) do
      bak = "#{p}.bak.#{System.os_time(:second)}"
      File.cp!(p, bak)
      prune_backups(p)
      bak
    end
  end

  defp prune_backups(p) do
    dir = Path.dirname(p)
    prefix = Path.basename(p) <> ".bak."

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.sort(:desc)
        |> Enum.drop(@backups_kept)
        |> Enum.each(&File.rm(Path.join(dir, &1)))

      _ ->
        :ok
    end
  end

  @doc "Load the raw config map, returning sane defaults when the file is absent."
  def load do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map |> migrate()
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
  # A model connection's identity is a stable, never-changing `id` (the map key
  # in the config file) - `name` is just a display label, free to rename without
  # ever touching the default_model/agent.model/cron.model references that
  # point at it. `get_model/1` accepts either an id or a (current) name, so
  # every existing caller that passes a human-typed name keeps working.

  @doc "List all model connections as structs."
  def models do
    load()
    |> Map.get("models", %{})
    |> Enum.map(fn {id, m} -> Model.from_map(Map.put(m, "id", id)) end)
  end

  @doc "Fetch a model connection by id or by its current name."
  def get_model(id_or_name) do
    case load() |> get_in(["models", id_or_name]) do
      nil -> Enum.find(models(), &(&1.name == id_or_name))
      m -> Model.from_map(Map.put(m, "id", id_or_name))
    end
  end

  def get_model!(id_or_name) do
    get_model(id_or_name) || raise "unknown model connection: #{inspect(id_or_name)}"
  end

  @doc "The stable id for a model given its current name or its id, or nil if unknown."
  def model_id_for(nil), do: nil
  def model_id_for(id_or_name), do: (get_model(id_or_name) || %{id: nil}).id

  @doc """
  The current display name for a model id. Falls back to the input unchanged
  when it isn't a known id, so a stale/foreign reference stays visible (e.g.
  for `Pepe.Doctor` to flag) instead of silently vanishing.
  """
  def model_name_for(nil), do: nil
  def model_name_for(id), do: (get_model(id) || %{name: id}).name

  @doc "Insert or update a model connection (matched by id, falling back to its current name)."
  def put_model(%Model{name: name} = model) do
    id = model.id || model_id_for(name) || generate_model_id()

    load()
    |> update_in(["models"], fn m -> Map.put(m || %{}, id, encode_model(%{model | id: id})) end)
    |> maybe_default_root("default_model", id)
    |> save()
  end

  def delete_model(id_or_name) do
    id = model_id_for(id_or_name) || id_or_name

    load()
    |> update_in(["models"], &Map.delete(&1 || %{}, id))
    |> clear_default_if("default_model", id)
    |> save()
  end

  @doc """
  Rename a model connection: since every reference to it is id-based, this is
  just a field update - the default_model/agent.model/cron.model pointers
  aiming at its id are entirely unaffected. Only the two fields that are still
  name-based (other models' `fallbacks`, the llm_redact hook's model) get
  rewritten. A rename can't cross company scope (a model's `acme/` prefix, if
  any, must stay put - that's how a model's tenant is determined).
  """
  def rename_model(old, new) do
    cond do
      get_model(old) == nil -> {:error, :not_found}
      old == new -> :ok
      Company.of(old) != Company.of(new) -> {:error, :scope_mismatch}
      not is_nil(model = get_model(new)) and model.id != model_id_for(old) -> {:error, :already_exists}
      true -> do_rename_model(old, new)
    end
  end

  defp do_rename_model(old, new) do
    put_model(%{get_model(old) | name: new})

    load()
    |> remap_fallbacks_everywhere(old, new)
    |> model_rename_in_hook("llm_redact", "model", old, new)
    |> save()

    :ok
  end

  defp remap_fallbacks_everywhere(config, old, new) do
    case Map.get(config, "models") do
      m when is_map(m) ->
        Map.put(config, "models", Map.new(m, fn {k, v} -> {k, model_rename_list(v, "fallbacks", old, new)} end))

      _ ->
        config
    end
  end

  defp model_rename_in_hook(config, hook, field, old, new) do
    case get_in(config, ["hooks", hook]) do
      m when is_map(m) -> put_in(config, ["hooks", hook], model_rename_exact(m, field, old, new))
      _ -> config
    end
  end

  # Strict equality only - unlike remap_handle/remap_field (used for company
  # renames), a model name isn't a hierarchical "company/thing" handle, so no
  # prefix-matching is appropriate here.
  defp model_rename_exact(map, field, old, new) do
    case Map.get(map, field) do
      ^old -> Map.put(map, field, new)
      _ -> map
    end
  end

  defp model_rename_list(map, field, old, new) do
    case Map.get(map, field) do
      list when is_list(list) -> Map.put(map, field, Enum.map(list, &if(&1 == old, do: new, else: &1)))
      _ -> map
    end
  end

  defp generate_model_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  # One-time, idempotent upgrade from the old models-keyed-by-name shape to the
  # current id-keyed shape. Runs on every load/0; a no-op after the first
  # (successful) run, since the shape check below then reads false.
  defp migrate(config) do
    if needs_model_id_migration?(config) do
      config |> migrate_model_ids() |> save()
    else
      config
    end
  end

  defp needs_model_id_migration?(config) do
    case Map.get(config, "models") do
      m when is_map(m) and map_size(m) > 0 ->
        {_k, v} = Enum.at(m, 0)
        not Map.has_key?(v, "name")

      _ ->
        false
    end
  end

  defp migrate_model_ids(config) do
    old_models = Map.get(config, "models", %{})
    id_map = Map.new(old_models, fn {name, _v} -> {name, generate_model_id()} end)
    new_models = Map.new(old_models, fn {name, v} -> {id_map[name], Map.put(v, "name", name)} end)

    config
    |> Map.put("models", new_models)
    |> migrate_ref("default_model", id_map)
    |> migrate_company_defaults(id_map)
    |> migrate_owned_refs("agents", "model", id_map)
    |> migrate_owned_refs("crons", "model", id_map)
  end

  defp migrate_ref(config, field, id_map) do
    case Map.get(config, field) do
      name when is_binary(name) -> Map.put(config, field, Map.get(id_map, name, name))
      _ -> config
    end
  end

  defp migrate_company_defaults(config, id_map) do
    case Map.get(config, "companies") do
      m when is_map(m) ->
        Map.put(config, "companies", Map.new(m, fn {co, v} -> {co, migrate_company_default(v, co, id_map)} end))

      _ ->
        config
    end
  end

  defp migrate_company_default(v, co, id_map) do
    case Map.get(v, "default_model") do
      nil ->
        v

      ref ->
        id = Map.get(id_map, Company.handle(co, ref)) || Map.get(id_map, ref)
        Map.put(v, "default_model", id || ref)
    end
  end

  defp migrate_owned_refs(config, section, field, id_map) do
    case Map.get(config, section) do
      m when is_map(m) ->
        Map.put(config, section, Map.new(m, fn {k, v} -> {k, migrate_owned_ref(v, field, k, id_map)} end))

      _ ->
        config
    end
  end

  defp migrate_owned_ref(v, field, owner_key, id_map) do
    case Map.get(v, field) do
      nil ->
        v

      ref when is_binary(ref) ->
        scope = Company.of(Map.get(v, "agent") || owner_key)
        id = Map.get(id_map, Company.handle(scope, ref)) || Map.get(id_map, ref)
        Map.put(v, field, id || ref)

      _ ->
        v
    end
  end

  def default_model_name, do: model_name_for(load()["default_model"])

  def default_model do
    case load()["default_model"] do
      nil -> nil
      id -> get_model(id)
    end
  end

  def set_default_model(name_or_id) do
    load() |> Map.put("default_model", model_id_for(name_or_id) || name_or_id) |> save()
  end

  @doc "Set the default model for a scope: global for root, or the company's own."
  def set_default_model_for(nil, name), do: set_default_model(name)

  def set_default_model_for(company, name_or_id) do
    id = model_id_for(name_or_id) || name_or_id

    load()
    |> update_in(["companies", company], fn m -> Map.put(m || %{}, "default_model", id) end)
    |> save()
  end

  ###
  ### Companies (multi-tenant scopes)
  ###

  @doc """
  Names of all configured companies (the tenant scopes), sorted. The **root** scope
  is not a company - it's the implicit default every command uses without
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
  itself, its agents and models (and any `company/...` references in `can_message` /
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
    |> remap_model_names(old, new)
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

  # Re-key a handle-keyed map (agents/models): rename `old/...` keys and transform the
  # value with `tx`.
  defp rekey_section(config, section, old, new, tx) do
    case Map.get(config, section) do
      m when is_map(m) ->
        Map.put(config, section, Map.new(m, fn {k, v} -> {remap_handle(k, old, new), tx.(v)} end))

      _ ->
        config
    end
  end

  # Models are id-keyed (their map key never changes), so a company rename
  # rewrites each affected model's `name` field in place instead of re-keying
  # the section the way rekey_section/5 does for agents.
  defp remap_model_names(config, old, new) do
    case Map.get(config, "models") do
      m when is_map(m) ->
        Map.put(config, "models", Map.new(m, fn {id, v} -> {id, remap_field(v, "name", old, new)} end))

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

  # In an id->entry map (crons/watches), remap each entry's `"agent"` handle.
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
  bare-name agents; a company returns only its own - never another's.
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
    |> Enum.map(fn {name, a} -> Agent.from_map(Map.put(a, "name", name)) |> resolve_agent_model() end)
  end

  @spec get_agent(String.t()) :: Agent.t() | nil
  def get_agent(name) do
    case load() |> get_in(["agents", name]) do
      nil -> nil
      a -> Agent.from_map(Map.put(a, "name", name)) |> resolve_agent_model()
    end
  end

  def get_agent!(name) do
    get_agent(name) || raise "unknown agent: #{inspect(name)}"
  end

  def put_agent(%Agent{name: name} = agent) do
    stored = %{agent | model: model_id_for(agent.model) || agent.model}

    load()
    |> update_in(["agents"], fn a -> Map.put(a || %{}, name, encode(stored)) end)
    |> maybe_default_root("default_agent", name)
    |> save()
  end

  # An agent's stored `model` is a model id (rename-safe); resolve it back to
  # the model's current name so every caller of Config.get_agent/agents (which
  # all expect `.model` to be a name, same as before model ids existed) sees
  # no difference.
  defp resolve_agent_model(%Agent{model: nil} = agent), do: agent
  defp resolve_agent_model(%Agent{model: id} = agent), do: %{agent | model: model_name_for(id)}

  @doc "Persistently approve `tool` for `agent_name` (the `:always` permission grant)."
  def allow_tool(agent_name, tool) do
    case get_agent(agent_name) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | auto_approve: Enum.uniq([tool | agent.auto_approve])})
    end
  end

  @doc "Allow `from` to message `to` (a directed route; `to -> from` is unaffected)."
  def allow_message(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_message: Enum.uniq(agent.can_message ++ [to])})
    end
  end

  @doc "Remove the `from -> to` route."
  def disallow_message(from, to) do
    case get_agent(from) do
      nil -> {:error, :unknown_agent}
      agent -> put_agent(%{agent | can_message: List.delete(agent.can_message, to)})
    end
  end

  @doc """
  May `admin` administer the agent named `target`? Authority defaults to CLOSED:

    * `can_manage == nil` -> itself only (a mild default).
    * `[]` -> nobody, not even itself (a locked child).
    * `[names]` -> exactly those (list is exhaustive - include its own name to also
      manage itself).
    * `["*"]` -> everyone (an explicit super-admin, never implicit).
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
        |> rename_default_agent(old, new)
        |> save()

      :error ->
        {:error, :not_found}
    end
  end

  defp rename_default_agent(%{"default_agent" => old} = config, old, new),
    do: Map.put(config, "default_agent", new)

  defp rename_default_agent(config, _old, _new), do: config

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
      id -> get_model(id) || default_model()
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
  The failover chain for an agent: its model followed by a fallback list
  (resolved, deduped, missing names dropped). Transient errors walk down the
  chain. The fallback list is the agent's own `fallbacks` when it has
  overridden one (a list, even `[]` for "none") - otherwise the model
  connection's own `fallbacks`, so every agent sharing a connection gets its
  reliability behavior for free unless it opts out.
  """
  def model_chain_for_agent(%Agent{fallbacks: override} = agent) when is_list(override) do
    build_chain(model_for_agent(agent), override)
  end

  def model_chain_for_agent(%Agent{} = agent) do
    primary = model_for_agent(agent)
    build_chain(primary, primary && primary.fallbacks)
  end

  defp build_chain(nil, _names), do: []

  defp build_chain(primary, names) do
    fallbacks = (names || []) |> Enum.map(&get_model/1) |> Enum.reject(&is_nil/1)
    Enum.uniq_by([primary | fallbacks], & &1.name)
  end

  ###
  ### Scheduled tasks (crons)
  ###

  @doc "All configured crons, as `Pepe.Config.Cron` structs."
  def crons do
    load()
    |> Map.get("crons", %{})
    |> Enum.map(fn {id, map} -> Cron.from_map(Map.put(map, "id", id)) |> resolve_cron_model() end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Fetch one cron by id, or nil."
  def get_cron(id) do
    case load() |> get_in(["crons", id]) do
      nil -> nil
      map -> Cron.from_map(Map.put(map, "id", id)) |> resolve_cron_model()
    end
  end

  @doc "Create or replace a cron (keyed by its `id`)."
  def put_cron(%Cron{id: id} = cron) when is_binary(id) do
    stored = %{cron | model: model_id_for(cron.model) || cron.model}
    map = stored |> Map.from_struct() |> Map.delete(:id) |> stringify()

    load()
    |> update_in(["crons"], fn c -> Map.put(c || %{}, id, map) end)
    |> save()
  end

  # Same rename-safety trick as resolve_agent_model/1: a cron's stored `model`
  # is an id, resolved back to a display name for every existing caller.
  defp resolve_cron_model(%Cron{model: nil} = cron), do: cron
  defp resolve_cron_model(%Cron{model: id} = cron), do: %{cron | model: model_name_for(id)}

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
  stored - never the raw token.
  """
  def api_tokens do
    load()
    |> Map.get("api_tokens", %{})
    |> Enum.map(fn {id, m} -> Map.put(m, "id", id) end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Is API auth on? It turns on the moment the first token exists - with none, the
  `/v1` API stays open (single-tenant/backward-compatible). Creating a token locks it.
  """
  def api_auth_required?, do: api_tokens() != []

  @doc """
  Mint an API token scoped to `company` (nil = root) and optionally `agent` (a full
  handle). Returns `{raw_token, id}`; for a regular token, the raw value is shown once
  and only its hash is stored - a leaked config can't be replayed. `agent` must be
  within `company`.

  Pass `widget: true` to mint a **widget token**: meant to sit in public page source
  (an embedded chat bubble's script tag), so it must be `agent`-locked (never
  company-wide or root - a public credential always pins to one known-safe agent).
  Give it `allowed_origin` (a scheme+host, e.g. `"https://example.com"`); the
  WebSocket only accepts connections whose browser `Origin` matches some registered
  widget token's origin (see `PepeWeb.AgentSocket.check_origin?/1`) - a coarse gate in
  front of the token itself, which still carries the real per-request authorization.
  Unlike a regular token, a widget token's raw value IS also stored (not just its
  hash) and stays retrievable via `widget_token/1` - it sits in public HTML already
  (anyone can read it with "view source" on the embedding site), so treating it as a
  secret that can never be shown again only costs a needless rotation the moment
  someone loses their copy of the snippet, with no real confidentiality gained. Its
  actual protection is `allowed_origin` + the agent lock + the rate limit, not secrecy
  of the string itself.

  A widget token also optionally carries its own **appearance** - `title`, `logo`,
  `color`, `theme`, `greeting`, `position` - fetched by the widget script at load time
  (`PepeWeb.WidgetConfigController`) and merged over the embed snippet's `data-*`
  attributes. Unlike the token's security-relevant fields (hash, scope, origin), these
  are freely editable in place afterwards via `update_widget_token/2` - tweaking a
  greeting or color is not a rotate-worthy change.
  """
  @widget_appearance_fields ~w(title logo color theme greeting position)a

  def add_api_token(opts \\ []) do
    company = opts[:company]
    agent = opts[:agent]
    widget? = opts[:widget] == true

    case validate_api_token(company, agent, widget?) do
      :ok -> create_api_token(company, agent, widget?, opts)
      error -> error
    end
  end

  defp validate_api_token(company, agent, widget?) do
    cond do
      widget? and is_nil(agent) -> {:error, :widget_needs_agent}
      unknown_company?(company) -> {:error, :unknown_company}
      agent_out_of_scope?(agent, company) -> {:error, :agent_out_of_scope}
      unknown_agent?(agent) -> {:error, :unknown_agent}
      true -> :ok
    end
  end

  defp unknown_company?(company), do: company && not company_exists?(company)
  defp agent_out_of_scope?(agent, company), do: agent && Company.of(agent) != company
  defp unknown_agent?(agent), do: agent && is_nil(get_agent(agent))

  defp create_api_token(company, agent, widget?, opts) do
    raw = Pepe.ApiToken.generate()
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    entry =
      %{
        "hash" => Pepe.ApiToken.hash(raw),
        "company" => company,
        "agent" => agent,
        "label" => opts[:label],
        "prefix" => Pepe.ApiToken.fingerprint(raw)
      }
      |> maybe_put("kind", widget? && "widget")
      |> maybe_put("allowed_origin", widget? && blank_to_nil(opts[:allowed_origin]))
      |> maybe_put("token", widget? && raw)
      |> put_appearance(widget?, opts)

    load()
    |> update_in(["api_tokens"], fn t -> Map.put(t || %{}, id, entry) end)
    |> save()

    {:ok, raw, id}
  end

  defp put_appearance(entry, false, _opts), do: entry

  defp put_appearance(entry, true, opts) do
    Enum.reduce(@widget_appearance_fields, entry, fn field, acc ->
      maybe_put(acc, to_string(field), blank_to_nil(opts[field]))
    end)
  end

  @doc """
  Update a widget token's **appearance** (`title`/`logo`/`color`/`theme`/`greeting`/
  `position`) in place - never its hash, scope, or `allowed_origin`, which stay
  rotate-only (see `add_api_token/1`). Every appearance field is always set to
  whatever `opts` gives it (blank clears it) - the appearance form always submits all
  of them together. `label` is different: only touched if `opts` actually has that
  key, so a caller that only edits appearance (no label field in its form) can't
  accidentally wipe an existing one. Returns `:ok`, `{:error, :not_found}`, or
  `{:error, :not_widget}` (a regular token has no appearance to edit).
  """
  def update_widget_token(id, opts) do
    case get_in(load(), ["api_tokens", id]) do
      nil ->
        {:error, :not_found}

      %{"kind" => "widget"} = entry ->
        updated =
          @widget_appearance_fields
          |> Enum.reduce(entry, fn field, acc -> Map.put(acc, to_string(field), blank_to_nil(opts[field])) end)
          |> maybe_put_label(opts)

        load() |> put_in(["api_tokens", id], updated) |> save()
        :ok

      _ ->
        {:error, :not_widget}
    end
  end

  defp maybe_put_label(entry, opts) do
    if Keyword.has_key?(opts, :label), do: Map.put(entry, "label", blank_to_nil(opts[:label])), else: entry
  end

  defp maybe_put(map, _key, falsy) when falsy in [false, nil], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_to_nil(v), do: v

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
  The raw value of a **widget** token by id, or `nil` if the id doesn't exist or
  isn't a widget token (a regular token's raw value was never stored - see
  `add_api_token/1`).
  """
  @spec widget_token(String.t()) :: String.t() | nil
  def widget_token(id) do
    case get_in(load(), ["api_tokens", id]) do
      %{"kind" => "widget", "token" => raw} -> raw
      _ -> nil
    end
  end

  @doc """
  A widget token's appearance config, looked up by its raw value (as the widget
  script itself would present it) - `%{title:, logo:, color:, theme:, greeting:,
  position:, allowed_origin:}`, each field `nil` if never set. `nil` if `raw` doesn't
  match any widget token. Used by `PepeWeb.WidgetConfigController`, so the widget can
  fetch its look from the dashboard instead of needing it baked into the embed
  snippet.
  """
  @spec widget_config(String.t()) :: map() | nil
  def widget_config(raw) when is_binary(raw) do
    hash = Pepe.ApiToken.hash(raw)

    case Enum.find(api_tokens(), &(&1["kind"] == "widget" and &1["hash"] == hash)) do
      nil ->
        nil

      t ->
        @widget_appearance_fields
        |> Map.new(&{&1, t[to_string(&1)]})
        |> Map.put(:allowed_origin, t["allowed_origin"])
    end
  end

  def widget_config(_raw), do: nil

  @doc """
  Verify a raw bearer token. Returns its scope `%{company: c, agent: a, kind: k,
  allowed_origin: o}` (`company`/`agent`/`allowed_origin` may be nil; `kind` is
  `"widget"` for a widget token, else nil) when it matches a stored hash, or `nil`
  when it doesn't.
  """
  def verify_api_token(raw) when is_binary(raw) do
    hash = Pepe.ApiToken.hash(raw)

    case Enum.find(api_tokens(), &(&1["hash"] == hash)) do
      nil -> nil
      t -> %{company: t["company"], agent: t["agent"], kind: t["kind"], allowed_origin: t["allowed_origin"]}
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
  live under `"telegrams"` (a name->config map), each bound to its own agent. Bots
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
  ### Webhook channels (WhatsApp, ...)
  ###

  @doc """
  All webhook connections as a `slug => entry` map. Each entry binds a provider
  (`\"whatsapp\"`, ...) and an agent to a URL `/webhooks/:company/:provider/:slug`.
  """
  def webhooks, do: load() |> Map.get("webhooks", %{})

  @doc "Fetch one webhook connection by its unique slug, or nil."
  def get_webhook(slug), do: load() |> get_in(["webhooks", slug])

  @doc "Does a webhook connection with this slug exist?"
  def webhook_exists?(slug), do: not is_nil(get_webhook(slug))

  @doc "Create or replace a webhook connection (keyed by its slug)."
  def put_webhook(slug, map) when is_binary(slug) and is_map(map) do
    clean = Map.delete(map, "slug")

    load()
    |> update_in(["webhooks"], fn w -> Map.put(w || %{}, slug, clean) end)
    |> save()
  end

  @doc "Delete a webhook connection."
  def delete_webhook(slug) do
    load()
    |> update_in(["webhooks"], &Map.delete(&1 || %{}, slug))
    |> save()
  end

  ###
  ### Hooks (message-flow transforms - PII redaction, ...)
  ###

  @doc """
  How inbound attachments are turned into text before the agent sees them (`media`).

  Today only `"audio"`, whose keys are read by `Pepe.Media`: `model` (a connection by
  name), `command` (a local transcriber, `{file}` substituted), `language`, `max_mb`,
  `timeout`, `echo`. All optional: with none of them set, a connection that already
  serves transcription is used.
  """
  def media, do: load() |> Map.get("media", %{})

  @doc "Replace the settings for one media kind (`\"audio\"`)."
  def put_media(kind, settings) when is_binary(kind) and is_map(settings) do
    load()
    |> update_in(["media"], fn m -> Map.put(m || %{}, kind, settings) end)
    |> save()
  end

  @doc "Global per-hook settings (`name => settings`), e.g. `pii_redact`'s packs/custom."
  def hooks_settings, do: load() |> Map.get("hooks", %{})

  @doc "Settings for one hook by name, or `%{}`."
  def hook_settings(name), do: hooks_settings() |> Map.get(name, %{})

  @doc "Replace one hook's global settings map."
  def put_hook_settings(name, settings) when is_binary(name) and is_map(settings) do
    load()
    |> update_in(["hooks"], fn h -> Map.put(h || %{}, name, settings) end)
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

  @doc "Saved settings for a plugin (by name) as a `%{key => value}` map. Secrets may be `${ENV_VAR}` refs."
  def plugin_config(name), do: load() |> get_in(["plugins", name]) || %{}

  @doc "Create or replace a plugin's settings map."
  def put_plugin_config(name, map) when is_binary(name) and is_map(map) do
    load()
    |> update_in(["plugins"], fn m -> Map.put(m || %{}, name, map) end)
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
  Path to the sandbox wrapper program that `bash`/`run_script` run commands through
  (Docker, firejail, sandbox-exec, ...), or `nil` to run directly on the host. See
  `Pepe.Sandbox`.
  """
  def sandbox do
    case load()["sandbox"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  @doc "Set (or clear, with nil) the sandbox wrapper program."
  def set_sandbox(nil), do: load() |> Map.delete("sandbox") |> save()
  def set_sandbox(path) when is_binary(path), do: load() |> Map.put("sandbox", path) |> save()

  @doc """
  The billing currency symbol/code used to label costs (default `\"USD\"`). Prices
  are entered and shown in this currency; there is no FX conversion.
  """
  def currency, do: load()["currency"] || "USD"

  @doc "Set the billing currency label."
  def set_currency(code), do: load() |> Map.put("currency", code) |> save()

  @doc """
  The dashboard password, or nil when unset. Read from config `dashboard.password`
  (`${ENV}`-interpolated so the secret stays out of the file) with a fallback to the
  `PEPE_DASHBOARD_PASSWORD` env var. Unset = the dashboard is open (local dev).
  """
  def dashboard_password do
    case interpolate(get_in(load(), ["dashboard", "password"])) do
      p when is_binary(p) and p != "" -> p
      _ -> blank_env("PEPE_DASHBOARD_PASSWORD")
    end
  end

  @doc "Is the dashboard behind a password? (a dashboard password is configured)"
  def dashboard_auth_required?, do: not is_nil(dashboard_password())

  @doc """
  When on, autonomous writes (memory/skill consolidation) are staged for review via
  `Pepe.Approval` instead of applied directly. Off by default (opt-in safety).
  """
  def review_writes?, do: load()["review_writes"] == true

  @doc "Turn the autonomous-write review queue on or off."
  def set_review_writes(on?), do: load() |> Map.put("review_writes", on? == true) |> save()

  @doc """
  Extra `Host` header values the dashboard accepts besides loopback names (for
  serving behind a domain; also the anti DNS-rebinding allowlist). Default `[]`.
  """
  def dashboard_allowed_hosts, do: dashboard_list("allowed_hosts")

  @doc """
  Reverse proxies whose `X-Forwarded-For` may be trusted, as CIDRs or bare IPs
  (e.g. `["127.0.0.1", "10.0.0.0/8"]`). Empty (default) = trust no forwarding header.
  """
  def dashboard_trusted_proxies, do: dashboard_list("trusted_proxies")

  defp dashboard_list(key) do
    case get_in(load(), ["dashboard", key]) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp blank_env(var) do
    case System.get_env(var) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # The metadata map for a billing/limits scope: root's own top-level "root" key,
  # or a company's entry under "companies". Root always "exists" (it's the implicit
  # default every command uses without --company), so root reads/writes here never
  # hit the {:error, :not_found} a company update can.
  defp scope_config(nil), do: load()["root"] || %{}
  defp scope_config(company), do: get_company(company) || %{}

  @doc """
  Update a billing/limits scope's metadata: root's own top-level config, or a
  company's (same as `update_company/2`, `{:error, :not_found}` if unknown). Root
  always succeeds - it always "exists", there's nothing to look up.
  """
  @spec update_scope(String.t() | nil, map()) :: :ok | {:error, :not_found}
  def update_scope(nil, meta) do
    merged =
      scope_config(nil) |> Map.merge(meta) |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    load() |> Map.put("root", merged) |> save()
    :ok
  end

  def update_scope(company, meta), do: update_company(company, meta)

  @doc """
  A scope's billing markup: the multiplier applied to provider cost to get the
  amount to charge. Unset means `1.0` - bill exactly the provider cost.
  """
  @spec company_markup(String.t() | nil) :: float()
  def company_markup(company) do
    case scope_config(company)["markup"] do
      n when is_number(n) and n > 0 -> n / 1
      _ -> 1.0
    end
  end

  @doc """
  A scope's monthly spend cap in the billing currency, or `nil` for no cap. When
  set, the runtime refuses new model calls for that scope once the month-to-date
  billable total reaches it. Root has its own cap (stored outside "companies",
  since it isn't one), independent of every company's.
  """
  @spec company_budget(String.t() | nil) :: float() | nil
  def company_budget(company) do
    case scope_config(company)["budget"] do
      n when is_number(n) and n > 0 -> n / 1
      _ -> nil
    end
  end

  @doc """
  A scope's monthly cap on customer-originated messages, or `nil` for no cap.
  Independent of `company_budget/1` (the spend cap) - a scope can have either,
  both, or neither. See `Pepe.Usage.over_message_limit?/1`.
  """
  @spec company_message_limit(String.t() | nil) :: pos_integer() | nil
  def company_message_limit(company) do
    case scope_config(company)["message_limit"] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  Unix timestamp of `scope`'s last manual budget reset (see
  `Pepe.Usage.reset_budget/1`), or `nil` if it's never been reset. Once a new
  billing month starts, this naturally stops mattering - `Pepe.Usage.month_to_date/1`
  only ever looks at the current month's entries in the first place.
  """
  @spec company_budget_reset_at(String.t() | nil) :: integer() | nil
  def company_budget_reset_at(company) do
    case scope_config(company)["budget_reset_at"] do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc "Stamp `scope`'s budget as reset right now. `{:error, :not_found}` if an unknown company."
  @spec reset_company_budget(String.t() | nil) :: :ok | {:error, :not_found}
  def reset_company_budget(scope), do: update_scope(scope, %{"budget_reset_at" => System.system_time(:second)})

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

  # Models are id-keyed (unlike agents/companies, which are still name-keyed),
  # so it's :id that's redundant with the map key here, not :name.
  defp encode_model(%Model{} = model) do
    model |> Map.from_struct() |> Map.delete(:id) |> stringify()
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
