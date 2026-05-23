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

  alias Pepe.Project
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Config.Model

  # The slug of the project a fresh install is born with, and the one every command falls back to
  # when no project is given. It is a normal, renameable project; this is only its initial slug.
  @default_project_slug "default"

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
          {:ok, map} when is_map(map) ->
            migrate(map)

          _ ->
            # The file is present but unparseable (a truncated/half-written save, disk corruption).
            # Falling back to `default()` here would be catastrophic: the next mutation would
            # `load()` an empty config and `save()` it over the real one, wiping every model,
            # agent, project and token. A present-but-corrupt file is an error to raise, NOT a
            # missing file to default. (An absent file still defaults, below.)
            raise "#{short_path(path())} is present but not valid JSON - refusing to overwrite it " <>
                    "with defaults. Restore it from a backup (see `#{Path.rootname(path())}.bak`)."
        end

      {:error, _} ->
        default()
    end
  end

  defp default do
    default_id = generate_project_id()

    %{
      "default_model" => nil,
      "models" => %{},
      "default_agent" => nil,
      "agents" => %{},
      # Every install has at least one project (a tenant scope). A fresh one is born with a
      # single "default" project, and that project is the one every command uses when no
      # `--project` is given. It's a normal project - renameable, shown in `project list` - that
      # simply happens to be the omission target, pointed at by id so a rename never moves the
      # binding.
      "projects" => %{default_id => %{"slug" => @default_project_slug, "name" => "Default"}},
      "default_project" => default_id,
      "telegram" => %{"bot_token" => "${TELEGRAM_BOT_TOKEN}", "allowed_chats" => []},
      "server" => %{"port" => 4000}
    }
  end

  @doc "Persist the raw config map, creating the directory if needed."
  def save(map) when is_map(map) do
    File.mkdir_p!(home())
    # Write to a temp file and rename into place. `File.rename` is atomic on the same filesystem,
    # so a reader never sees a half-written config and a crash mid-write leaves the old file
    # intact rather than a truncated one (which `load/0` would now refuse anyway).
    tmp = path() <> ".tmp"
    File.write!(tmp, Jason.encode!(map, pretty: true))
    File.rename!(tmp, path())
    map
  end

  @doc """
  Atomically read-modify-write the config: `fun` receives the current config map and returns the
  new one. The whole load→modify→save runs under a lock, so two concurrent mutations can't each
  load the same state, change different slices, and have the last save silently drop the other's
  change (a lost update). Every mutator in this module goes through here; a bare `load |> ... |>
  save` from anywhere else re-opens that race, so don't.

  Not reentrant: `fun` must not call another mutator that itself calls `update/1`, or the inner
  save would be clobbered by the outer. Compose the changes into one `fun` instead.
  """
  @spec update((map() -> map())) :: map()
  def update(fun) when is_function(fun, 1), do: Pepe.Config.Writer.update(fun)

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

    update(fn config ->
      config
      |> update_in(["models"], fn m -> Map.put(m || %{}, id, encode_model(%{model | id: id})) end)
      |> maybe_default_root("default_model", id)
    end)
  end

  def delete_model(id_or_name) do
    id = model_id_for(id_or_name) || id_or_name

    update(fn config ->
      config
      |> update_in(["models"], &Map.delete(&1 || %{}, id))
      |> clear_default_if("default_model", id)
    end)
  end

  @doc """
  Rename a model connection: since every reference to it is id-based, this is
  just a field update - the default_model/agent.model/cron.model pointers
  aiming at its id are entirely unaffected. Only the two fields that are still
  name-based (other models' `fallbacks`, the llm_redact hook's model) get
  rewritten. A rename can't cross project scope (a model's `acme/` prefix, if
  any, must stay put - that's how a model's tenant is determined).
  """
  def rename_model(old, new) do
    cond do
      get_model(old) == nil -> {:error, :not_found}
      old == new -> :ok
      Project.of(old) != Project.of(new) -> {:error, :scope_mismatch}
      not is_nil(model = get_model(new)) and model.id != model_id_for(old) -> {:error, :already_exists}
      true -> do_rename_model(old, new)
    end
  end

  defp do_rename_model(old, new) do
    put_model(%{get_model(old) | name: new})

    update(fn config ->
      config
      |> remap_fallbacks_everywhere(old, new)
      |> model_rename_in_hook("llm_redact", "model", old, new)
    end)

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

  # Strict equality only - unlike remap_handle/remap_field (used for project
  # renames), a model name isn't a hierarchical "project/thing" handle, so no
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

  defp generate_project_id, do: "p_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  # One-time, idempotent upgrade from the old models-keyed-by-name shape to the
  # current id-keyed shape. Runs on every load/0; a no-op after the first
  # (successful) run, since the shape check below then reads false.
  #
  # Order matters and is a dependency chain, not a preference: projects must exist
  # (migrate_to_projects) before agents can be re-keyed onto project ids
  # (migrate_agents_to_ids maps each agent's slug -> project id). Keep this sequence.
  defp migrate(config) do
    config
    |> maybe_migrate(&needs_model_id_migration?/1, &migrate_model_ids/1)
    |> maybe_migrate(&needs_project_migration?/1, &migrate_to_projects/1)
    |> maybe_migrate(&needs_agent_id_migration?/1, &migrate_agents_to_ids/1)
  end

  # Upgrade agents from handle-keyed (`slug/name`) to id-keyed: each gets a stable id and stores
  # its bare label + owning project id, so renaming a project or an agent never re-keys it.
  # Handle-shaped references (default_agent, cron/bot/token bindings, can_message) stay as handles
  # and resolve at read time. Runs once, after the projects migration (which it depends on).
  defp needs_agent_id_migration?(config) do
    config
    |> Map.get("agents", %{})
    |> Enum.any?(fn {_k, m} -> is_map(m) and not Map.has_key?(m, "project") end)
  end

  defp migrate_agents_to_ids(config) do
    agents =
      config
      |> Map.get("agents", %{})
      |> Map.new(fn
        # Already id-keyed (has "project") - leave it alone. Re-keying an already-migrated entry
        # would treat its id as a bare name and mangle it; only touch old handle-keyed entries.
        {id, %{"project" => _} = m} ->
          {id, m}

        {handle, m} ->
          {slug, bare} = handle_parts(config, handle)
          pid = project_id_for(config, slug)
          {generate_agent_id(), m |> Map.drop(["name"]) |> Map.put("bare", bare) |> Map.put("project", pid)}
      end)

    config = Map.put(config, "agents", agents)

    # Second pass, now that every agent has an id: convert each agent's `can_message`/`can_manage`
    # handles to agent ids, so those routing/authority lists are rename-safe too. (Single bindings
    # - default_agent, cron/bot/token `agent` - need no migration pass: a stored handle reads back
    # transparently and every new write stores an id.)
    update_in(config, ["agents"], fn ags ->
      Map.new(ags, fn {id, m} ->
        {id,
         m
         |> Map.update("can_message", [], &store_agent_refs(config, &1))
         |> Map.update("can_manage", nil, &store_agent_refs(config, &1))}
      end)
    end)
  end

  # Run a one-time, idempotent upgrade and persist it, or pass the config through untouched. Each
  # migration's `needs?` check reads false once its shape is in place, so it fires at most once.
  defp maybe_migrate(config, needs?, migrate) do
    if needs?.(config), do: config |> migrate.() |> save(), else: config
  end

  # Upgrade the old "root scope + companies" shape to the uniform "projects" shape: the implicit
  # root becomes a real `default` project, each project becomes a project keyed by a stable id
  # (slug = old name), every bare (root) handle is qualified into the default project - agents and
  # every reference to them (default_agent, cron/watch/bot/token bindings, can_message/can_manage)
  # - and root's own billing (the old top-level "root" key) folds into the default project. Reuses
  # the same remap helpers a project rename uses, with `old = nil` (the bare/root scope).
  defp needs_project_migration?(config), do: not Map.has_key?(config, "projects")

  defp migrate_to_projects(config) do
    default_id = generate_project_id()
    default_slug = @default_project_slug

    project_projects =
      config
      |> Map.get("companies", %{})
      |> Map.new(fn {slug, meta} ->
        {generate_project_id(), Map.merge(%{"slug" => slug, "name" => slug}, meta)}
      end)

    default_meta = Map.merge(config["root"] || %{}, %{"slug" => default_slug, "name" => "Default"})
    projects = Map.put(project_projects, default_id, default_meta)

    config
    |> Map.put("projects", projects)
    |> Map.put("default_project", default_id)
    |> Map.delete("companies")
    |> Map.delete("root")
    # Re-key bare (root) agent handles into the default project, but leave each agent body alone:
    # bare `can_message`/`can_manage` entries are resolved against the sender's scope at runtime
    # (`Project.qualify/2`), so qualifying them here would wrongly pin same-project peers.
    |> rekey_section("agents", nil, default_slug, & &1)
    |> rewrite_agent_binding("crons", nil, default_slug)
    |> rewrite_agent_binding("watches", nil, default_slug)
    |> rewrite_bot_bindings(nil, default_slug)
    |> migrate_token_agents(default_slug)
    |> remap_field("default_agent", nil, default_slug)
  end

  # Qualify only a token's bare `agent` handle into the default project. The token's `project`
  # field is a project slug, not a handle, and is left untouched: a project token keeps its slug,
  # and a root token keeps `project: nil` (the open scope), resolved to the default at use time
  # (`resolve_scope/1`) rather than rewritten here.
  defp migrate_token_agents(config, default_slug) do
    case Map.get(config, "api_tokens") do
      m when is_map(m) ->
        Map.put(config, "api_tokens", Map.new(m, fn {id, e} -> {id, remap_field(e, "agent", nil, default_slug)} end))

      _ ->
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
    |> migrate_project_defaults(id_map)
    |> migrate_owned_refs("agents", "model", id_map)
    |> migrate_owned_refs("crons", "model", id_map)
  end

  defp migrate_ref(config, field, id_map) do
    case Map.get(config, field) do
      name when is_binary(name) -> Map.put(config, field, Map.get(id_map, name, name))
      _ -> config
    end
  end

  defp migrate_project_defaults(config, id_map) do
    case Map.get(config, "companies") do
      m when is_map(m) ->
        Map.put(config, "companies", Map.new(m, fn {co, v} -> {co, migrate_project_default(v, co, id_map)} end))

      _ ->
        config
    end
  end

  defp migrate_project_default(v, co, id_map) do
    case Map.get(v, "default_model") do
      nil ->
        v

      ref ->
        id = Map.get(id_map, Project.handle(co, ref)) || Map.get(id_map, ref)
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
        scope = Project.of(Map.get(v, "agent") || owner_key)
        id = Map.get(id_map, Project.handle(scope, ref)) || Map.get(id_map, ref)
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
    id = model_id_for(name_or_id) || name_or_id
    update(fn config -> Map.put(config, "default_model", id) end)
  end

  @doc "Set the default model for a scope: the global default for `nil`, or a project's own."
  def set_default_model_for(nil, name), do: set_default_model(name)

  def set_default_model_for(scope, name_or_id) do
    id = model_id_for(name_or_id) || name_or_id
    update_project(scope, %{"default_model" => id})
  end

  ###
  ### Projects (multi-tenant scopes)
  ###
  #
  # The "projects" map is id-keyed. Each entry carries a stable `slug` (the path-safe handle used
  # in `slug/agent`, workspace dirs and URLs - renameable) and a free `name` (display label).
  # `default_project` points at one id: the scope every command falls back to when none is given.
  # Keying by id means renaming a slug never moves the default binding. See `Pepe.Project` for the
  # handle math.

  @doc "All projects, each as `%{\"id\" => ..., \"slug\" => ..., \"name\" => ..., ...meta}`, sorted by slug."
  def projects do
    load()
    |> projects_of()
    |> Enum.map(fn {id, m} -> Map.put(m, "id", id) end)
    |> Enum.sort_by(& &1["slug"])
  end

  @doc """
  The id of the default project - the scope every command falls back to when no project is given.
  Falls back to the first project if the pointer is missing or dangles (a hand-edited config),
  so resolution never crashes.
  """
  def default_project_id, do: resolve_default_id(load())

  # The projects map from a config snapshot (empty if absent). Threaded rather than re-read so it
  # works both outside a lock (from `load()`) and inside `update/1` (on the locked snapshot).
  defp projects_of(config), do: Map.get(config, "projects", %{})

  defp resolve_default_id(config) do
    projects = projects_of(config)
    pointer = config["default_project"]

    if is_binary(pointer) and Map.has_key?(projects, pointer),
      do: pointer,
      else: projects |> Map.keys() |> Enum.sort() |> List.first()
  end

  @doc "The slug of the default project - what an omitted scope resolves to."
  def default_project_slug, do: default_project_slug(load())

  defp default_project_slug(config) do
    case resolve_default_id(config) do
      nil -> @default_project_slug
      id -> get_in(config, ["projects", id, "slug"]) || @default_project_slug
    end
  end

  @doc "Resolve an optional scope to a concrete slug: `nil` becomes the default project's slug."
  def resolve_scope(nil), do: default_project_slug()
  def resolve_scope(slug) when is_binary(slug), do: slug

  @doc """
  Qualify a bare handle into the default project (`assistant` -> `default/assistant`); an
  already-qualified handle (`acme/vendas`) is returned unchanged. This is the "bare by omission"
  rule at the storage boundary: a handle with no project part belongs to the default project, so
  every agent is stored and looked up under a fully-qualified `project/name` key.
  """
  def resolve_handle(handle), do: resolve_handle(load(), handle)

  defp resolve_handle(config, handle) when is_binary(handle) do
    case Project.of(handle) do
      nil -> Project.handle(default_project_slug(config), handle)
      _ -> handle
    end
  end

  defp resolve_handle(_config, handle), do: handle

  # The project id for an id (passed straight through) or a slug; nil if neither matches.
  defp project_id_for(config, id_or_slug) do
    projects = projects_of(config)

    if is_binary(id_or_slug) and Map.has_key?(projects, id_or_slug) do
      id_or_slug
    else
      Enum.find_value(projects, &slug_match(&1, id_or_slug))
    end
  end

  defp slug_match({id, %{"slug" => slug}}, slug), do: id
  defp slug_match(_entry, _slug), do: nil

  @doc "Fetch a project's metadata (with its `id`) by id or slug, or nil."
  def get_project(id_or_slug) do
    config = load()

    case project_id_for(config, id_or_slug) do
      nil -> nil
      id -> config |> get_in(["projects", id]) |> Map.put("id", id)
    end
  end

  @doc "Does a project with this id or slug exist?"
  def project_exists?(id_or_slug), do: not is_nil(get_project(id_or_slug))

  @doc """
  The **additional** projects' slugs, sorted - every project except the default one. The default
  project is the home scope every command falls back to, surfaced on its own (as "Principal" in
  the dashboard, explained by `pepe project` when the list is empty), so it isn't listed here.
  """
  def project_slugs do
    default = default_project_slug()
    projects() |> Enum.map(& &1["slug"]) |> Enum.reject(&(&1 == default)) |> Enum.sort()
  end

  @doc """
  Create a project (a tenant scope) with a path-safe `slug`. `meta` is free-form
  (e.g. `%{\"name\" => ..., \"description\" => ...}`); `slug` and a `\"created\"` marker are kept,
  and `name` defaults to the slug. Returns `:ok`, `{:error, :invalid_slug}` or
  `{:error, :already_exists}`.
  """
  def add_project(slug, meta \\ %{}) do
    cond do
      not Project.valid_name?(slug) ->
        {:error, :invalid_slug}

      project_exists?(slug) ->
        {:error, :already_exists}

      true ->
        update(&insert_project(&1, generate_project_id(), slug, meta))
        :ok
    end
  end

  defp insert_project(config, id, slug, meta) do
    entry =
      meta
      |> Map.put("slug", slug)
      |> Map.put_new("name", slug)
      |> Map.put_new("created", true)

    update_in(config, ["projects"], fn p -> Map.put(p || %{}, id, entry) end)
  end

  @doc """
  Update a project's metadata (e.g. its `"description"` or billing fields) by id or slug. Merges
  `meta` over the existing entry, dropping keys whose value is nil, always keeping the `"slug"`
  identity and the `"created"` marker. The slug never changes here - use `rename_project/2`. Fails
  with `{:error, :not_found}` if unknown.
  """
  def update_project(id_or_slug, meta) do
    case project_id_for(load(), id_or_slug) do
      nil ->
        {:error, :not_found}

      _ ->
        update(fn config -> apply_to_project(config, id_or_slug, meta) end)
        :ok
    end
  end

  defp apply_to_project(config, id_or_slug, meta) do
    case project_id_for(config, id_or_slug) do
      nil ->
        config

      id ->
        existing = get_in(config, ["projects", id]) || %{}

        merged =
          existing
          |> Map.merge(meta)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
          |> Map.put("slug", existing["slug"])
          |> Map.put("created", true)

        put_in(config, ["projects", id], merged)
    end
  end

  @doc "Set a project's display `name`. Never re-keys anything. `{:error, :not_found}` if unknown."
  def set_project_name(id_or_slug, name), do: update_project(id_or_slug, %{"name" => name})

  @doc """
  Make `id_or_slug` the default project - the scope every command falls back to when none is
  given. `{:error, :not_found}` if unknown.
  """
  def set_default_project(id_or_slug) do
    case get_project(id_or_slug) do
      nil ->
        {:error, :not_found}

      %{"id" => id} ->
        update(fn config -> Map.put(config, "default_project", id) end)
        :ok
    end
  end

  @doc """
  Delete a project by id or slug. Refuses to delete the **last** project (there is always at
  least one), or the **current default** (`{:error, :is_default}` - set another default first, so
  the omission target never moves out from under you by surprise), or a project that still owns
  agents unless `force: true` (which also drops those agents; their workspace files stay on disk).
  """
  def delete_project(id_or_slug, opts \\ []) do
    config = load()

    case project_id_for(config, id_or_slug) do
      nil ->
        {:error, :not_found}

      id ->
        slug = get_in(config, ["projects", id, "slug"])

        cond do
          map_size(projects_of(config)) <= 1 ->
            {:error, :last_project}

          id == resolve_default_id(config) ->
            {:error, :is_default}

          agents_in(slug) != [] and not Keyword.get(opts, :force, false) ->
            {:error, {:not_empty, length(agents_in(slug))}}

          true ->
            update(&drop_project(&1, id, slug))
            :ok
        end
    end
  end

  defp drop_project(config, id, _slug) do
    agents = Map.get(config, "agents", %{})
    # Agents are id-keyed and carry their owning project id; filter on that, not on the handle
    # (which is the opaque agent id here, never a `slug/name`), or the project's agents survive as
    # orphans and resurface under the default project.
    kept = Map.reject(agents, fn {_id, m} -> m["project"] == id end)

    config
    |> Map.put("agents", kept)
    |> update_in(["projects"], &Map.delete(&1 || %{}, id))
  end

  @doc """
  Rename a project's **slug** (by id or current slug), re-keying everything that carries it: the
  project's own `slug` field, its agents and models (and any `slug/...` references in `can_message`
  / `can_manage`), and the `agent` binding of every cron, watch, bot and API token that points at
  one of its agents. The project's stable id never changes, so the `default_project` binding is
  untouched. Also moves its workspace and usage directories on disk. Free text (prompts,
  descriptions) is never touched.

  Fails on an invalid or already-taken new slug, or an unknown project. Best done while idle: any
  in-flight session keyed by an old handle simply finishes; new requests use the new handle.
  """
  def rename_project(id_or_slug, new_slug) do
    old =
      case get_project(id_or_slug) do
        %{"slug" => s} -> s
        nil -> nil
      end

    cond do
      not Project.valid_name?(new_slug) -> {:error, :invalid_slug}
      is_nil(old) -> {:error, :not_found}
      old == new_slug -> :ok
      project_exists?(new_slug) -> {:error, :already_exists}
      true -> do_rename_project(old, new_slug)
    end
  end

  defp do_rename_project(old, new) do
    update(fn config ->
      config
      |> rename_project_slug(old, new)
      # Agents are id-keyed, so the project rename doesn't re-key them - only their handle-shaped
      # references (can_message/can_manage) that embed the old slug are re-pointed.
      |> remap_agents_refs(old, new)
      |> remap_model_names(old, new)
      |> rewrite_agent_binding("crons", old, new)
      |> rewrite_agent_binding("watches", old, new)
      |> rewrite_bot_bindings(old, new)
      |> rewrite_token_scopes(old, new)
      |> remap_field("default_agent", old, new)
      |> remap_field("default_model", old, new)
    end)

    move_project_dirs(old, new)
    :ok
  end

  # A handle in `old`'s scope becomes the same name in `new`; the bare project slug
  # (e.g. a token's `"project"`) is remapped too. Anything else is left alone.
  defp remap_handle(h, old, new) when is_binary(h) do
    cond do
      h == old -> new
      Project.of(h) == old -> Project.handle(new, Project.name_of(h))
      true -> h
    end
  end

  defp remap_handle(h, _old, _new), do: h

  # Rename a project's slug in place. The projects map is id-keyed, so the entry's key (its id)
  # never changes - only its "slug" field is rewritten.
  defp rename_project_slug(config, old, new) do
    update_in(config, ["projects"], fn projects ->
      Map.new(projects || %{}, fn {id, m} ->
        {id, if(m["slug"] == old, do: Map.put(m, "slug", new), else: m)}
      end)
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

  # Models are id-keyed (their map key never changes), so a project rename
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
            {id, e |> remap_field("project", old, new) |> remap_field("agent", old, new)}
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

  # Move every per-scope directory keyed by a project's slug when the slug is renamed: the agents'
  # workspaces/shared under `projects/<slug>/`, and the usage, traces and messages ledgers.
  defp move_project_dirs(old, new) do
    for base <- [
          Path.join(home(), "projects"),
          Path.join([home(), "data", "usage"]),
          Path.join([home(), "data", "traces"]),
          Path.join([home(), "data", "messages"])
        ] do
      src = Path.join(base, old)
      dst = Path.join(base, new)
      if File.dir?(src) and not File.exists?(dst), do: File.rename(src, dst)
    end

    :ok
  end

  @doc """
  Build a self-contained, **root-scoped** config holding only `project`, with its
  `project/thing` handles de-scoped to bare root names - the config a fresh, single-tenant
  install would have if this project were the only thing on it. Nothing is saved; the map is
  returned for a caller (`Pepe.Bundle`) to write into a bundle.

  De-scoping is the same handle rewrite a rename does, aimed at the empty scope: `remap_handle`
  with `new == ""` turns `acme/sales` into `sales` (see `Project.handle/2`). Only the project's
  own agents, models, crons, watches, bots and tokens travel, plus any **shared/root model** a
  kept agent points at (agents reference models by id, so a shared dependency is pulled in whole
  rather than left dangling). The `projects` map, the `default_project` pointer and the root bot
  binding are dropped; every
  other top-level key (server, sandbox, secrets, pricing, timezone) is an install-wide setting
  and rides along unchanged.

  Returns `{:ok, config, %{secrets: [String.t()], shared_models: [String.t()]}}`, or
  `{:error, :not_found}` for an unknown project. `secrets` are the `${ENV_VAR}` names the
  extracted config still references (they live outside the files and must be provisioned on the
  destination); `shared_models` are the names of the root/shared models pulled in as
  dependencies, so the caller can point them out.
  """
  @spec extract_config(String.t()) ::
          {:ok, map(), %{secrets: [String.t()], shared_models: [String.t()], literal_secrets: [String.t()]}}
          | {:error, :not_found}
  def extract_config(project) do
    if project_exists?(project) do
      config = load()
      {new, shared} = build_extracted(config, project)

      {:ok, new,
       %{
         secrets: provisioning_env(new),
         shared_models: shared,
         literal_secrets: literal_secrets(new)
       }}
    else
      {:error, :not_found}
    end
  end

  # Sections keyed or bound to a scope, which are filtered to the project and de-scoped. The whole
  # `projects` map and the `default_project` pointer are dropped: the bundle is bare single-tenant,
  # and load-time migration re-expands it into a fresh default project. The legacy single
  # `telegram` bot is dropped outright too.
  @scoped_sections ~w(agents models crons watches telegrams api_tokens webhooks)
  @dropped_sections ~w(projects default_project telegram)

  # A scope's billing/limits fields (kept in the project's own entry under `projects.<id>`).
  @billing_keys ~w(markup budget message_limit budget_reset_at)

  # A project's meta (billing, defaults) by slug, from a config snapshot (empty if unknown).
  defp project_meta_in(config, slug) do
    case project_id_for(config, slug) do
      nil -> %{}
      id -> get_in(config, ["projects", id]) || %{}
    end
  end

  defp build_extracted(config, co) do
    agents = keep_owned_agents(config["agents"], project_id_for(config, co))
    crons = config["crons"] |> resolve_section_agents(config) |> keep_agent_bound(co)
    watches = config["watches"] |> resolve_section_agents(config) |> keep_agent_bound(co)
    telegrams = config["telegrams"] |> resolve_section_agents(config) |> keep_agent_bound(co)
    tokens = config["api_tokens"] |> resolve_section_agents(config) |> keep_tokens(co)
    webhooks = config["webhooks"] |> resolve_section_agents(config) |> keep_webhooks(co)
    meta = project_meta_in(config, co)

    deps = model_deps(agents, [crons, watches, telegrams], meta)
    {models, shared} = keep_models(config["models"], deps, co)

    rebuilt = %{
      "agents" => descope_agents(agents, co),
      "models" => descope_model_names(models, co),
      "crons" => descope_agent_bound(crons, co),
      "watches" => descope_agent_bound(watches, co),
      "telegrams" => descope_agent_bound(telegrams, co),
      "api_tokens" => descope_tokens(tokens, co),
      "webhooks" => descope_webhooks(webhooks, co)
    }

    new =
      config
      |> Map.drop(@scoped_sections ++ @dropped_sections)
      |> Map.merge(rebuilt)
      |> Map.put("default_agent", descope_name(meta["default_agent"], co))
      |> Map.put("default_model", descope_name(meta["default_model"], co))
      |> put_root_billing(meta)

    {new, shared}
  end

  # The project's own billing/limits become the bundle's root scope. The source install's `root`
  # billing (a different tenant's markup and spend caps) is dropped above and never carried; and
  # the project's cap must survive the move, or the standalone install starts with no ceiling.
  defp put_root_billing(config, meta) do
    case Map.take(meta, @billing_keys) do
      billing when map_size(billing) == 0 -> config
      billing -> Map.put(config, "root", billing)
    end
  end

  # Resolve every entry's `"agent"` field (an agent id) back to a handle, so the extract's
  # scope-filtering and de-scoping (which work on handles) see handles regardless of storage.
  defp resolve_section_agents(section, config) when is_map(section),
    do: Map.new(section, fn {k, e} -> {k, resolve_entry_agent(e, config)} end)

  defp resolve_section_agents(other, _config), do: other

  defp resolve_entry_agent(%{"agent" => a} = e, config) when is_binary(a),
    do: Map.put(e, "agent", ref_to_handle(config, a))

  defp resolve_entry_agent(e, _config), do: e

  # Id-keyed agents belonging to project `pid`.
  defp keep_owned_agents(section, pid) when is_map(section),
    do: Map.filter(section, fn {_id, m} -> m["project"] == pid end)

  defp keep_owned_agents(_section, _pid), do: %{}

  # Id-keyed section whose entries carry an `"agent"` handle (crons/watches/telegrams), filtered
  # to entries bound to one of the project's agents.
  defp keep_agent_bound(section, co) when is_map(section),
    do: Map.filter(section, fn {_id, e} -> Project.of(e["agent"] || "") == co end)

  defp keep_agent_bound(_section, _co), do: %{}

  # A token may be scoped to a project by its `"project"` field (a bare name, e.g. from
  # `token add --project acme` with no agent) OR bound to one of its agents. Filtering by the
  # agent alone drops the whole-tenant token, which is the commonest shape when standing an
  # install up on its own. Webhooks are the same: an inbound connection is scoped by its own
  # `"project"` and routes to an `"agent"`.
  defp keep_tokens(section, co) when is_map(section),
    do: Map.filter(section, fn {_id, e} -> scoped_to?(e, co) end)

  defp keep_tokens(_section, _co), do: %{}

  defp keep_webhooks(section, co) when is_map(section),
    do: Map.filter(section, fn {_slug, e} -> scoped_to?(e, co) end)

  defp keep_webhooks(_section, _co), do: %{}

  # An entry belongs to `co` if its bare `"project"` names it, or its `"agent"` handle is in it.
  defp scoped_to?(entry, co),
    do: entry["project"] == co or Project.of(entry["agent"] || "") == co

  # Every model the bundle needs, by every way a model is pointed at. `.model`, a cron/watch/bot
  # `.model` override, and a scope `default_model` are stored as model **ids**; an agent's
  # `triage_model`/`simple_model`/`utility_model` and its `fallbacks` are stored as model
  # **names**. Missing any of these routes leaves a root/shared dependency out of the bundle and
  # the reference dangling on the restored install (a silent loss of the default model, the
  # triage hook, or a fallback), so all of them are collected.
  defp model_deps(agents, id_sections, meta) do
    agent_vals = Map.values(agents)

    ids =
      (Enum.map(agent_vals, & &1["model"]) ++
         Enum.flat_map(id_sections, fn sec -> sec |> Map.values() |> Enum.map(& &1["model"]) end) ++
         [meta["default_model"]])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    names =
      agent_vals
      |> Enum.flat_map(fn a ->
        [a["triage_model"], a["simple_model"], a["utility_model"]] ++ List.wrap(a["fallbacks"])
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{ids: ids, names: names}
  end

  # Models the bundle needs: the project's own (by name scope), plus any **root/shared** model a
  # kept reference points at (by id or by name), so a shared dependency travels whole. A model
  # that belongs to *another* project is deliberately NEVER pulled in, even when referenced -
  # carrying it would leak that tenant's connection (base_url, headers, the name of its secret)
  # into this bundle. Such a cross-project reference is a misconfiguration, and dropping it fails
  # closed: the restored agent has a dangling ref rather than a stranger's credentials. Returns
  # the kept id->model map and the names of the pulled-in shared ones (for the caller to report).
  defp keep_models(models, deps, co) when is_map(models) do
    kept =
      Map.filter(models, fn {id, m} ->
        name = m["name"] || ""

        case Project.of(name) do
          ^co -> true
          nil -> MapSet.member?(deps.ids, id) or MapSet.member?(deps.names, name)
          _other_project -> false
        end
      end)

    shared =
      kept
      |> Enum.filter(fn {_id, m} -> Project.of(m["name"] || "") != co end)
      |> Enum.map(fn {_id, m} -> m["name"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    {kept, shared}
  end

  defp keep_models(_models, _deps, _co), do: {%{}, []}

  # Produce the extracted bare-root (old-shape) agents map: keyed by bare name, with the id-keyed
  # `bare`/`project` fields stripped and scope references de-scoped. Restore's migration re-expands
  # it into the default project.
  defp descope_agents(agents, co) do
    Map.new(agents, fn {_id, m} ->
      {m["bare"], m |> Map.drop(["bare", "project"]) |> rewrite_agent_refs(co, "") |> descope_model_hooks(co)}
    end)
  end

  # An agent's model-hook fields (`triage_model`/`simple_model`/`utility_model`) and its
  # `fallbacks` list hold model NAMES, so a project one (`acme/triage`) must lose its prefix the
  # same way the model's own name does, or it matches nothing on the restored install.
  defp descope_model_hooks(agent, co) do
    agent
    |> remap_field("triage_model", co, "")
    |> remap_field("simple_model", co, "")
    |> remap_field("utility_model", co, "")
    |> remap_list("fallbacks", co, "")
  end

  defp descope_model_names(models, co),
    do: Map.new(models, fn {id, v} -> {id, remap_field(v, "name", co, "")} end)

  defp descope_agent_bound(section, co),
    do: Map.new(section, fn {id, v} -> {id, remap_field(v, "agent", co, "")} end)

  defp descope_tokens(section, co) do
    Map.new(section, fn {id, e} ->
      {id, e |> descope_scope_project(co) |> remap_field("agent", co, "")}
    end)
  end

  defp descope_webhooks(section, co) do
    Map.new(section, fn {slug, e} ->
      {slug, e |> descope_scope_project(co) |> remap_field("agent", co, "")}
    end)
  end

  # A token's/webhook's `project` is a bare name, not a handle, and the root scope is `nil`
  # everywhere it is read (token_in_scope?, verify_api_token, webhook `norm`, the usage/agent
  # scoping). De-scoping it to root must land on `nil`, not the `""` a handle remap would give -
  # otherwise the restored entry is scoped to a project that does not exist and matches nothing.
  defp descope_scope_project(entry, co) do
    case Map.get(entry, "project") do
      ^co -> Map.put(entry, "project", nil)
      _ -> entry
    end
  end

  # A stored default handle (`acme/sales`) becomes its bare name; nil stays nil.
  defp descope_name(nil, _co), do: nil
  defp descope_name(handle, co), do: remap_handle(handle, co, "")

  @doc """
  The environment variables a destination must have for `config` to resolve its secrets: every
  `${ENV_VAR}` it references, plus the vault-opening credentials named in `secrets.vault_env`
  (which a vault resolver reads to open the vault, and which are *not* written as `${VAR}`, so
  a plain `${VAR}` scan would miss them). Sorted and unique. Used by `extract`/`restore` and
  `backup` to tell the operator what to provision, since none of these ever live in the archive.
  """
  @spec provisioning_env(map()) :: [String.t()]
  def provisioning_env(config) when is_map(config) do
    (env_refs(config) ++ vault_env_names(config)) |> Enum.uniq() |> Enum.sort()
  end

  # Every `${ENV_VAR}` the given config still points at, sorted and unique.
  defp env_refs(config) do
    ~r/\$\{([A-Z0-9_]+)\}/
    |> Regex.scan(Jason.encode!(config), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp vault_env_names(config) do
    case get_in(config, ["secrets", "vault_env"]) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  # Config field names that hold a credential across models and webhook providers.
  @secret_config_keys ~w(access_token app_secret app_password signing_secret bot_token client_secret token secret api_key password)

  @doc """
  Labels for every place in `config` that holds a **raw** credential (not a `${ENV_VAR}`,
  `exec:` or `file:` reference) - an OAuth login's stored tokens, a model's inline `api_key`, a
  webhook provider secret typed literally. These *are* written into a backup/extract archive, so
  "no secret is in the archive" is only true when this list is empty; when it is not, the caller
  warns that the archive carries live credentials to rotate or re-authenticate on the
  destination. Sorted and unique.
  """
  @spec literal_secrets(map()) :: [String.t()]
  def literal_secrets(config) when is_map(config) do
    models = for {_id, m} <- config["models"] || %{}, label = model_literal(m), not is_nil(label), do: label
    hooks = for {slug, e} <- config["webhooks"] || %{}, webhook_literal?(e), do: "webhook:#{slug}"

    (models ++ hooks) |> Enum.uniq() |> Enum.sort()
  end

  defp model_literal(m) do
    cond do
      is_map(m["oauth"]) -> "model:#{m["name"]} (OAuth login - re-authenticate on the destination)"
      raw_secret?(m["api_key"]) -> "model:#{m["name"]} (inline api_key)"
      true -> nil
    end
  end

  defp webhook_literal?(entry) do
    cfg = entry["config"] || %{}
    Enum.any?(@secret_config_keys, fn key -> raw_secret?(cfg[key]) end)
  end

  # A non-empty string that is not one of the three reference forms is a credential sitting in
  # the file in the clear.
  defp raw_secret?(v) when is_binary(v) and v != "",
    do: not (String.starts_with?(v, "${") or String.starts_with?(v, "exec:") or String.starts_with?(v, "file:"))

  defp raw_secret?(_), do: false

  @doc """
  Agents in a scope: `nil` resolves to the default project, or pass a project slug. Returns only
  that project's agents - never another's.
  """
  def agents_in(scope) do
    slug = resolve_scope(scope)
    agents() |> Enum.filter(fn a -> Project.of(a.name) == slug end)
  end

  ###
  ### Agents
  ###

  def agents do
    config = load()

    config
    |> Map.get("agents", %{})
    |> Enum.map(fn {id, m} -> build_agent(config, id, m) end)
  end

  # Build the Agent struct from a stored (id-keyed) map: fill the stable `id`, owning `project`
  # id and bare label, and the derived display handle in `name` (`<project-slug>/<bare>`), so
  # callers keep seeing a handle in `.name`.
  defp build_agent(config, id, m) do
    agent =
      m
      |> Map.put("id", id)
      |> Map.put("name", agent_handle(config, m))
      |> Agent.from_map()
      |> resolve_agent_model()

    # Routing/authority lists are STORED as agent ids (rename-safe); resolve them back to handles
    # on read so every caller sees handles exactly as before. A non-agent entry (`"*"`, or a stale
    # id) passes through untouched. `can_manage: nil` (the "itself only" default) is preserved.
    %{
      agent
      | can_message: resolve_agent_refs(config, agent.can_message),
        can_manage: resolve_agent_refs(config, agent.can_manage)
    }
  end

  defp resolve_agent_refs(config, refs) when is_list(refs), do: Enum.map(refs, &ref_to_handle(config, &1))
  defp resolve_agent_refs(_config, other), do: other

  # An agent id -> its display handle; anything else (a bare name, `"*"`, an unresolvable id) as-is.
  defp ref_to_handle(config, ref) do
    case get_in(config, ["agents", ref]) do
      m when is_map(m) -> agent_handle(config, m)
      _ -> ref
    end
  end

  # A handle -> the agent's stable id for storage; a non-resolving entry (`"*"`, a bare peer name
  # that has no agent yet) is kept verbatim so nothing is silently dropped.
  defp handle_to_ref(config, handle), do: agent_id_for(config, handle) || handle

  defp store_agent_refs(config, refs) when is_list(refs), do: Enum.map(refs, &handle_to_ref(config, &1))
  defp store_agent_refs(_config, other), do: other

  # A single agent binding (a cron/bot/token `agent`, or `default_agent`): store the handle as its
  # stable id, and resolve a stored id back to its handle on read. A nil or non-resolving value
  # (e.g. a token with no agent) passes through untouched, so nothing is lost.
  defp store_agent_ref(nil), do: nil
  defp store_agent_ref(handle), do: handle_to_ref(load(), handle)

  defp read_agent_ref(nil), do: nil
  defp read_agent_ref(ref), do: ref_to_handle(load(), ref)

  # Transform a raw map's `"agent"` field (a bot/token map) in place, only if the key is present -
  # so an empty telegram map never gains a stray `"agent" => nil` key.
  defp read_map_agent(m) when is_map(m),
    do: if(Map.has_key?(m, "agent"), do: Map.update!(m, "agent", &read_agent_ref/1), else: m)

  defp store_map_agent(m) when is_map(m),
    do: if(Map.has_key?(m, "agent"), do: Map.update!(m, "agent", &store_agent_ref/1), else: m)

  # Prepare an agent for id-keyed storage: pin its bare label + owning project, store the model by
  # id, and store its routing/authority lists as agent ids (so a rename never rewrites them).
  defp store_agent(config, %Agent{} = agent, bare, pid) do
    %{
      agent
      | model: model_id_for(agent.model) || agent.model,
        bare: bare,
        project: pid,
        can_message: store_agent_refs(config, agent.can_message),
        can_manage: store_agent_refs(config, agent.can_manage)
    }
  end

  # The display handle `<project-slug>/<bare>` for a stored agent map.
  defp agent_handle(config, m) do
    slug = get_in(config, ["projects", m["project"], "slug"]) || default_project_slug(config)
    Project.handle(slug, m["bare"])
  end

  # Resolve an agent reference - an agent id, or a handle (`slug/name`, or a bare name that
  # resolves into the default project) - to the agent's stable id, or nil.
  defp agent_id_for(config, ref) when is_binary(ref) do
    agents = Map.get(config, "agents", %{})

    if Map.has_key?(agents, ref) do
      ref
    else
      {slug, bare} = handle_parts(config, ref)
      pid = project_id_for(config, slug)
      Enum.find_value(agents, &agent_match(&1, pid, bare))
    end
  end

  defp agent_id_for(_config, _ref), do: nil

  defp agent_match({id, %{"project" => pid, "bare" => bare}}, pid, bare), do: id
  defp agent_match(_entry, _pid, _bare), do: nil

  # Re-point every agent's handle-shaped refs (can_message/can_manage) from `old` to `new`, without
  # re-keying the id-keyed agents map. Used by a project rename.
  defp remap_agents_refs(config, old, new) do
    update_in(config, ["agents"], &remap_each_agent_refs(&1, old, new))
  end

  defp remap_each_agent_refs(agents, old, new) do
    Map.new(agents || %{}, fn {id, m} -> {id, rewrite_agent_refs(m, old, new)} end)
  end

  # {project-slug, bare-name} for a handle, filling an omitted project with the default.
  defp handle_parts(config, handle) do
    case Project.of(handle) do
      nil -> {default_project_slug(config), Project.name_of(handle)}
      slug -> {slug, Project.name_of(handle)}
    end
  end

  defp generate_agent_id, do: "a_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  @spec get_agent(String.t()) :: Agent.t() | nil
  def get_agent(ref) do
    config = load()

    case agent_id_for(config, ref) do
      nil -> nil
      id -> build_agent(config, id, config["agents"][id])
    end
  end

  def get_agent!(ref) do
    get_agent(ref) || raise "unknown agent: #{inspect(ref)}"
  end

  def put_agent(%Agent{name: name} = agent) do
    if valid_handle?(name) do
      do_put_agent(agent)
    else
      {:error, :invalid_name}
    end
  end

  # A handle is `slug/name` or a bare name; every segment must be a plain `[A-Za-z0-9_-]+` label
  # (the rule projects already enforce). This is the choke point every agent write flows through -
  # the CLI validated, but the manage_agent tool and the dashboard did not, which let a crafted
  # name (`acme/../../x`) reach the filesystem-path builder. Reject it here, and Workspace.dir
  # refuses it again as a backstop.
  defp valid_handle?(handle) do
    slug = Project.of(handle)
    (is_nil(slug) or Project.valid_name?(slug)) and Project.valid_name?(Project.name_of(handle))
  end

  defp do_put_agent(%Agent{name: name} = agent) do
    update(fn config ->
      {slug, bare} = handle_parts(config, name)
      {config, pid} = ensure_project(config, slug)
      id = agent.id || agent_id_for(config, name) || generate_agent_id()
      stored = store_agent(config, agent, bare, pid)

      config
      |> update_in(["agents"], fn a -> Map.put(a || %{}, id, encode_agent(stored)) end)
      |> maybe_default_root_agent(id, pid)
    end)
  end

  # {config, project-id} for a slug, creating the project (with that slug) if it doesn't exist -
  # so putting an agent into a not-yet-declared project just works, as it did when agents were
  # handle-keyed. (The CLI still validates and rejects an unknown `--project` before this.)
  defp ensure_project(config, slug) do
    case project_id_for(config, slug) do
      nil ->
        id = generate_project_id()
        {update_in(config, ["projects"], &Map.put(&1 || %{}, id, %{"slug" => slug, "name" => slug})), id}

      pid ->
        {config, pid}
    end
  end

  # Store an agent id-keyed: drop the derived `name` and the `id` (which is the map key); keep the
  # stable `bare` label and owning `project` id.
  defp encode_agent(%Agent{} = agent) do
    agent |> Map.from_struct() |> Map.drop([:id, :name]) |> stringify()
  end

  # An agent's stored `model` is a model id (rename-safe); resolve it back to
  # the model's current name so every caller of Config.get_agent/agents (which
  # all expect `.model` to be a name, same as before model ids existed) sees
  # no difference.
  defp resolve_agent_model(%Agent{model: nil} = agent), do: agent
  defp resolve_agent_model(%Agent{model: id} = agent), do: %{agent | model: model_name_for(id)}

  # Atomically read-modify-write one agent: `fun` gets the current Agent struct and returns the
  # modified one, with the read and the write under a single lock. A `get_agent` + `put_agent`
  # pair (the old shape) could lose a concurrent grant/route change to the SAME agent - both read
  # the old agent, and the second `put_agent` writes back the whole entry, dropping the first's
  # change. Returns `:ok`, or `{:error, :unknown_agent}`. (Callers ignore the success value.)
  defp update_agent(ref, fun) do
    case agent_id_for(load(), ref) do
      nil ->
        {:error, :unknown_agent}

      id ->
        update(&apply_to_agent(&1, id, fun))
        :ok
    end
  end

  defp apply_to_agent(config, id, fun) do
    case config["agents"][id] do
      raw when is_map(raw) ->
        updated = fun.(build_agent(config, id, raw))
        stored = store_agent(config, updated, raw["bare"], raw["project"])
        update_in(config, ["agents"], &Map.put(&1 || %{}, id, encode_agent(stored)))

      _ ->
        config
    end
  end

  @doc "Persistently approve `tool` for `agent_name` (the `:always` permission grant)."
  def allow_tool(agent_name, grant) do
    # Widen the grant this agent already has for that tool rather than piling a second entry
    # beside it, so the list stays something a human can audit at a glance.
    update_agent(agent_name, fn agent ->
      %{agent | auto_approve: Pepe.Permissions.Grant.merge(agent.auto_approve, grant)}
    end)
  end

  # Canonicalize a route/authority target relative to `from`'s scope: a bare `to` qualifies into
  # `from`'s project, then resolves to the target agent's canonical handle - so add/remove match
  # the resolved `can_message`/`can_manage` lists and the id-based storage lines up. `"*"` (the
  # can_manage wildcard) and an unresolved name pass through untouched.
  defp canon_target(_from, "*"), do: "*"

  defp canon_target(from, to) do
    from_handle = agent_display_handle(from)
    agent_display_handle(Project.qualify(to, from_handle))
  end

  defp agent_display_handle(ref) do
    case get_agent(ref) do
      %Agent{name: name} -> name
      _ -> to_string(ref)
    end
  end

  @doc "Allow `from` to message `to` (a directed route; `to -> from` is unaffected)."
  def allow_message(from, to) do
    target = canon_target(from, to)
    update_agent(from, fn agent -> %{agent | can_message: Enum.uniq(agent.can_message ++ [target])} end)
  end

  @doc "Remove the `from -> to` route."
  def disallow_message(from, to) do
    target = canon_target(from, to)
    update_agent(from, fn agent -> %{agent | can_message: List.delete(agent.can_message, target)} end)
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
    target = canon_target(from, to)
    update_agent(from, fn agent -> %{agent | can_manage: Enum.uniq((agent.can_manage || []) ++ [target])} end)
  end

  @doc "Revoke `from`'s authority over `to`."
  def disallow_manage(from, to) do
    target = canon_target(from, to)
    update_agent(from, fn agent -> %{agent | can_manage: List.delete(agent.can_manage || [], target)} end)
  end

  def delete_agent(ref) do
    update(fn config ->
      case agent_id_for(config, ref) do
        nil ->
          config

        id ->
          config
          |> update_in(["agents"], &Map.delete(&1 || %{}, id))
          |> clear_default_if("default_agent", id)
      end
    end)
  end

  # Set the global default_agent (an agent id) to this project's agent, if the agent belongs to
  # the default project and no default is set yet. An agent in another project must never become
  # the global default just by being the first one created.
  defp maybe_default_root_agent(config, id, pid) do
    if pid == resolve_default_id(config),
      do: maybe_default(config, "default_agent", id),
      else: config
  end

  defp project_slug_of(config, pid),
    do: get_in(config, ["projects", pid, "slug"]) || default_project_slug(config)

  @doc """
  Rename an agent - change its bare label and move its workspace directory. The agent's stable id
  never changes, so id-based references don't move; the handle references that still embed the
  bare name (`default_agent`, `can_message`/`can_manage`, cron/bot/token bindings) are re-pointed.
  """
  def rename_agent(old, new) do
    config = load()
    new_bare = Project.name_of(new)

    case agent_id_for(config, old) do
      nil ->
        {:error, :not_found}

      id ->
        m = config["agents"][id]
        old_handle = agent_handle(config, m)
        new_handle = Project.handle(project_slug_of(config, m["project"]), new_bare)

        cond do
          not Project.valid_name?(new_bare) ->
            {:error, :invalid_name}

          # Another agent in the same project already has this bare name: renaming onto it would
          # give two distinct ids the same derived handle and the same workspace dir.
          agent_name_taken?(config, id, m["project"], new_bare) ->
            {:error, :already_exists}

          true ->
            do_rename_agent(id, old_handle, new_handle, new_bare)
        end
    end
  end

  defp do_rename_agent(id, old_handle, new_handle, new_bare) do
    update(fn c ->
      c
      |> update_in(["agents", id], &Map.put(&1, "bare", new_bare))
      |> rekey_agent_refs(old_handle, new_handle)
    end)

    Pepe.Agent.Workspace.rename(old_handle, new_handle)
    :ok
  end

  defp agent_name_taken?(config, id, pid, bare) do
    config
    |> Map.get("agents", %{})
    |> Enum.any?(fn {other_id, m} -> other_id != id and m["project"] == pid and m["bare"] == bare end)
  end

  # Re-point every handle-shaped reference to an agent from `old` to `new` (used by rename_agent).
  # Does NOT re-key the id-keyed agents map - only the references that still carry a handle.
  defp rekey_agent_refs(config, old, new) do
    config
    |> update_in(["agents"], fn agents ->
      Map.new(agents || %{}, fn {id, m} -> {id, rewrite_agent_refs(m, old, new)} end)
    end)
    |> rewrite_agent_binding("crons", old, new)
    |> rewrite_agent_binding("watches", old, new)
    |> rewrite_bot_bindings(old, new)
    |> rewrite_token_scopes(old, new)
    |> remap_field("default_agent", old, new)
  end

  # The global default_agent is stored as an agent id; resolve it back to a handle for callers.
  def default_agent_name, do: read_agent_ref(load()["default_agent"])

  def default_agent do
    case load()["default_agent"] do
      nil -> nil
      ref -> get_agent(ref)
    end
  end

  def set_default_agent(name) do
    update(fn config -> Map.put(config, "default_agent", handle_to_ref(config, name)) end)
  end

  @doc """
  Set the default agent for a scope: the global default for `nil`, or a project's own default
  (stored as an agent id in the project meta) for a project slug.
  """
  def set_default_agent_for(nil, name), do: set_default_agent(name)

  def set_default_agent_for(scope, name),
    do: update_project(scope, %{"default_agent" => handle_to_ref(load(), Project.handle(scope, name))})

  @doc """
  The default model for a scope: a project's own default if it pins one (resolved in
  the project then the root scope), otherwise the root default. So projects can
  share the operator's global provider or pin their own isolated keys.
  """
  def default_model_for(nil), do: default_model()

  def default_model_for(project) do
    case (get_project(project) || %{})["default_model"] do
      nil -> default_model()
      id -> get_model(id) || default_model()
    end
  end

  @doc "The default agent handle for a scope, or nil. Root uses the global default."
  def default_agent_for(nil), do: default_agent_name()

  def default_agent_for(project) do
    case (get_project(project) || %{})["default_agent"] do
      nil -> nil
      ref -> read_agent_ref(ref)
    end
  end

  @doc """
  Resolve the model connection an agent should use. A project agent's model
  reference resolves within its own project first, then the root scope; an unset
  reference falls back to the scope's default model. Project keys stay invisible to
  other projects.
  """
  def model_for_agent(%Agent{name: handle, model: nil}), do: default_model_for(Project.of(handle))

  def model_for_agent(%Agent{name: handle, model: ref}) do
    scope = Project.of(handle)
    get_model(Project.handle(scope, ref)) || get_model(ref) || default_model_for(scope)
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
    |> Enum.map(fn {id, map} -> Cron.from_map(Map.put(map, "id", id)) |> resolve_cron_model() |> resolve_cron_agent() end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Fetch one cron by id, or nil."
  def get_cron(id) do
    case load() |> get_in(["crons", id]) do
      nil -> nil
      map -> Cron.from_map(Map.put(map, "id", id)) |> resolve_cron_model() |> resolve_cron_agent()
    end
  end

  defp resolve_cron_agent(%Cron{agent: agent} = cron), do: %{cron | agent: read_agent_ref(agent)}

  @doc "Create or replace a cron (keyed by its `id`)."
  def put_cron(%Cron{id: id} = cron) when is_binary(id) do
    stored = %{cron | model: model_id_for(cron.model) || cron.model, agent: store_agent_ref(cron.agent)}
    map = stored |> Map.from_struct() |> Map.delete(:id) |> stringify()

    update(fn config ->
      config
      |> update_in(["crons"], fn c -> Map.put(c || %{}, id, map) end)
    end)
  end

  # Same rename-safety trick as resolve_agent_model/1: a cron's stored `model`
  # is an id, resolved back to a display name for every existing caller.
  defp resolve_cron_model(%Cron{model: nil} = cron), do: cron
  defp resolve_cron_model(%Cron{model: id} = cron), do: %{cron | model: model_name_for(id)}

  @doc "Delete a cron by id."
  def delete_cron(id) do
    update(fn config ->
      config
      |> update_in(["crons"], &Map.delete(&1 || %{}, id))
    end)
  end

  ###
  ### Watches (one-shot "notify me when X" commitments)
  ###

  alias Pepe.Config.Watch

  @doc "All watches, as `Pepe.Config.Watch` structs, sorted by id."
  def watches do
    load()
    |> Map.get("watches", %{})
    |> Enum.map(fn {id, map} -> Watch.from_map(Map.put(map, "id", id)) |> resolve_watch_agent() end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Fetch one watch by id, or nil."
  def get_watch(id) do
    case load() |> get_in(["watches", id]) do
      nil -> nil
      map -> Watch.from_map(Map.put(map, "id", id)) |> resolve_watch_agent()
    end
  end

  defp resolve_watch_agent(%Watch{agent: agent} = watch), do: %{watch | agent: read_agent_ref(agent)}

  @doc "Create or replace a watch (keyed by its `id`)."
  def put_watch(%Watch{id: id} = watch) when is_binary(id) do
    map = %{watch | agent: store_agent_ref(watch.agent)} |> Map.from_struct() |> Map.delete(:id) |> stringify()

    update(fn config ->
      config
      |> update_in(["watches"], fn w -> Map.put(w || %{}, id, map) end)
    end)
  end

  @doc "Delete a watch by id."
  def delete_watch(id) do
    update(fn config ->
      config
      |> update_in(["watches"], &Map.delete(&1 || %{}, id))
    end)
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
    |> Enum.map(fn {id, m} -> m |> Map.put("id", id) |> Map.update("agent", nil, &read_agent_ref/1) end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Is API auth on? It turns on the moment the first token exists - with none, the
  `/v1` API stays open (single-tenant/backward-compatible). Creating a token locks it.
  """
  def api_auth_required?, do: api_tokens() != []

  @doc """
  Mint an API token scoped to `project` (nil = root) and optionally `agent` (a full
  handle). Returns `{raw_token, id}`; for a regular token, the raw value is shown once
  and only its hash is stored - a leaked config can't be replayed. `agent` must be
  within `project`.

  Pass `widget: true` to mint a **widget token**: meant to sit in public page source
  (an embedded chat bubble's script tag), so it must be `agent`-locked (never
  project-wide or root - a public credential always pins to one known-safe agent).
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
    project = opts[:project]
    agent = opts[:agent]
    widget? = opts[:widget] == true

    case validate_api_token(project, agent, widget?) do
      :ok -> create_api_token(project, agent, widget?, opts)
      error -> error
    end
  end

  defp validate_api_token(project, agent, widget?) do
    cond do
      widget? and is_nil(agent) -> {:error, :widget_needs_agent}
      unknown_project?(project) -> {:error, :unknown_project}
      agent_out_of_scope?(agent, project) -> {:error, :agent_out_of_scope}
      unknown_agent?(agent) -> {:error, :unknown_agent}
      true -> :ok
    end
  end

  defp unknown_project?(project), do: project && not project_exists?(project)

  defp agent_out_of_scope?(agent, project),
    do: agent && resolve_scope(Project.of(agent)) != resolve_scope(project)

  defp unknown_agent?(agent), do: agent && is_nil(get_agent(agent))

  defp create_api_token(project, agent, widget?, opts) do
    raw = Pepe.ApiToken.generate()
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    entry =
      %{
        "hash" => Pepe.ApiToken.hash(raw),
        "project" => project,
        "agent" => store_agent_ref(agent),
        "label" => opts[:label],
        "prefix" => Pepe.ApiToken.fingerprint(raw)
      }
      |> maybe_put("kind", widget? && "widget")
      |> maybe_put("allowed_origin", widget? && blank_to_nil(opts[:allowed_origin]))
      |> maybe_put("token", widget? && raw)
      |> put_appearance(widget?, opts)

    update(fn config ->
      config
      |> update_in(["api_tokens"], fn t -> Map.put(t || %{}, id, entry) end)
    end)

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

        update(fn config -> config |> put_in(["api_tokens", id], updated) end)
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
      update(fn config -> config |> update_in(["api_tokens"], &Map.delete(&1 || %{}, id)) end)
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

    case Enum.find(api_tokens(), &(&1["kind"] == "widget" and token_hash_match?(&1, hash))) do
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
  Verify a raw bearer token. Returns its scope `%{project: c, agent: a, kind: k,
  allowed_origin: o}` (`project`/`agent`/`allowed_origin` may be nil; `kind` is
  `"widget"` for a widget token, else nil) when it matches a stored hash, or `nil`
  when it doesn't.
  """
  def verify_api_token(raw) when is_binary(raw) do
    hash = Pepe.ApiToken.hash(raw)

    case Enum.find(api_tokens(), &token_hash_match?(&1, hash)) do
      nil -> nil
      t -> %{project: t["project"], agent: t["agent"], kind: t["kind"], allowed_origin: t["allowed_origin"]}
    end
  end

  def verify_api_token(_), do: nil

  # Constant-time compare of the stored token hash. The hashes are SHA-256 of the token, so a
  # timing side channel is not practically exploitable (the attacker can't steer the hash bits
  # without a preimage), but the secure compare is the correct default and costs nothing.
  defp token_hash_match?(entry, hash), do: Plug.Crypto.secure_compare(to_string(entry["hash"]), hash)

  ###
  ### Gateways
  ###

  def telegram do
    load() |> Map.get("telegram", %{}) |> read_map_agent()
  end

  def put_telegram(map) when is_map(map) do
    update(fn config -> config |> Map.put("telegram", store_map_agent(map)) end)
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
        m when is_map(m) and map_size(m) > 0 -> [Map.put(m, "name", m["name"] || "default") |> read_map_agent()]
        _ -> []
      end

    extra =
      load()
      |> Map.get("telegrams", %{})
      |> Enum.map(fn {name, m} -> m |> Map.put("name", name) |> read_map_agent() end)
      |> Enum.sort_by(& &1["name"])

    (base ++ extra)
    |> Enum.uniq_by(fn m -> interpolate(m["bot_token"]) || m["name"] end)
  end

  @doc "Fetch one Telegram bot config by name (`\"default\"` is the legacy one)."
  def telegram_bot(name), do: Enum.find(telegram_bots(), &(&1["name"] == name))

  @doc "Create or replace a named (non-default) Telegram bot."
  def put_telegram_bot(name, map) when is_binary(name) and is_map(map) do
    clean = map |> Map.delete("name") |> store_map_agent()

    update(fn config ->
      config
      |> update_in(["telegrams"], fn t -> Map.put(t || %{}, name, clean) end)
    end)
  end

  @doc """
  Delete a named Telegram bot.

  `"default"` is the odd one out: it is not in `telegrams` at all, it is the legacy
  singular `telegram` map that a fresh config is seeded with (so that exporting
  `TELEGRAM_BOT_TOKEN` is enough to get a bot, with nothing else to set up). Deleting it
  therefore means clearing that map, not removing a key from `telegrams`, which is why it
  used to be undeletable: the dashboard's remove button was hidden for it, and had it been
  shown it would have done nothing.
  """
  def delete_telegram_bot("default") do
    update(fn config ->
      config
      |> Map.put("telegram", %{})
    end)
  end

  def delete_telegram_bot(name) do
    update(fn config ->
      config
      |> update_in(["telegrams"], &Map.delete(&1 || %{}, name))
    end)
  end

  ###
  ### Webhook channels (WhatsApp, ...)
  ###

  @doc """
  All webhook connections as a `slug => entry` map. Each entry binds a provider
  (`\"whatsapp\"`, ...) and an agent to a URL `/webhooks/:project/:provider/:slug`.
  """
  def webhooks, do: load() |> Map.get("webhooks", %{})

  @doc "Fetch one webhook connection by its unique slug, or nil."
  def get_webhook(slug), do: load() |> get_in(["webhooks", slug])

  @doc "Does a webhook connection with this slug exist?"
  def webhook_exists?(slug), do: not is_nil(get_webhook(slug))

  @doc "Create or replace a webhook connection (keyed by its slug)."
  def put_webhook(slug, map) when is_binary(slug) and is_map(map) do
    clean = Map.delete(map, "slug")

    update(fn config ->
      config
      |> update_in(["webhooks"], fn w -> Map.put(w || %{}, slug, clean) end)
    end)
  end

  @doc "Delete a webhook connection."
  def delete_webhook(slug) do
    update(fn config ->
      config
      |> update_in(["webhooks"], &Map.delete(&1 || %{}, slug))
    end)
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
    update(fn config ->
      config
      |> update_in(["media"], fn m -> Map.put(m || %{}, kind, settings) end)
    end)
  end

  @doc "Global per-hook settings (`name => settings`), e.g. `pii_redact`'s packs/custom."
  def hooks_settings, do: load() |> Map.get("hooks", %{})

  @doc "Settings for one hook by name, or `%{}`."
  def hook_settings(name), do: hooks_settings() |> Map.get(name, %{})

  @doc "Replace one hook's global settings map."
  def put_hook_settings(name, settings) when is_binary(name) and is_map(settings) do
    update(fn config ->
      config
      |> update_in(["hooks"], fn h -> Map.put(h || %{}, name, settings) end)
    end)
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
    update(fn config ->
      config
      |> update_in(["mcp"], fn m -> Map.put(m || %{}, name, map) end)
    end)
  end

  @doc "Delete an MCP server definition."
  def delete_mcp_server(name) do
    update(fn config ->
      config
      |> update_in(["mcp"], &Map.delete(&1 || %{}, name))
    end)
  end

  @doc "Saved settings for a plugin (by name) as a `%{key => value}` map. Secrets may be `${ENV_VAR}` refs."
  def plugin_config(name), do: load() |> get_in(["plugins", name]) || %{}

  @doc "Create or replace a plugin's settings map."
  def put_plugin_config(name, map) when is_binary(name) and is_map(map) do
    update(fn config ->
      config
      |> update_in(["plugins"], fn m -> Map.put(m || %{}, name, map) end)
    end)
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
  def set_default_timezone(tz), do: update(fn config -> config |> Map.put("timezone", tz) end)

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
  def set_sandbox(nil), do: update(fn config -> config |> Map.delete("sandbox") end)
  def set_sandbox(path) when is_binary(path), do: update(fn config -> config |> Map.put("sandbox", path) end)

  @doc """
  The billing currency symbol/code used to label costs (default `\"USD\"`). Prices
  are entered and shown in this currency; there is no FX conversion.
  """
  def currency, do: load()["currency"] || "USD"

  @doc "Set the billing currency label."
  def set_currency(code), do: update(fn config -> config |> Map.put("currency", code) end)

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
  def set_review_writes(on?), do: update(fn config -> config |> Map.put("review_writes", on? == true) end)

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

  # The metadata map for a billing/limits scope. Uniform now: `nil` resolves to the default
  # project, any slug to its own project. Billing fields live in the project entry like any other
  # meta - there is no separate top-level "root" key, and no nil special case.
  defp scope_config(scope), do: get_project(resolve_scope(scope)) || %{}

  @doc """
  Update a billing/limits scope's metadata: `nil` resolves to the default project, a slug to its
  own. Same as `update_project/2`; `{:error, :not_found}` if unknown (the default always exists).
  """
  @spec update_scope(String.t() | nil, map()) :: :ok | {:error, :not_found}
  def update_scope(scope, meta), do: update_project(resolve_scope(scope), meta)

  @doc """
  A scope's billing markup: the multiplier applied to provider cost to get the
  amount to charge. Unset means `1.0` - bill exactly the provider cost.
  """
  @spec project_markup(String.t() | nil) :: float()
  def project_markup(project) do
    case scope_config(project)["markup"] do
      n when is_number(n) and n > 0 -> n / 1
      _ -> 1.0
    end
  end

  @doc """
  A scope's monthly spend cap in the billing currency, or `nil` for no cap. When
  set, the runtime refuses new model calls for that scope once the month-to-date
  billable total reaches it. Root has its own cap (stored outside "companies",
  since it isn't one), independent of every project's.
  """
  @spec project_budget(String.t() | nil) :: float() | nil
  def project_budget(project) do
    case scope_config(project)["budget"] do
      n when is_number(n) and n > 0 -> n / 1
      _ -> nil
    end
  end

  @doc """
  A scope's monthly cap on customer-originated messages, or `nil` for no cap.
  Independent of `project_budget/1` (the spend cap) - a scope can have either,
  both, or neither. See `Pepe.Usage.over_message_limit?/1`.
  """
  @spec project_message_limit(String.t() | nil) :: pos_integer() | nil
  def project_message_limit(project) do
    case scope_config(project)["message_limit"] do
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
  @spec project_budget_reset_at(String.t() | nil) :: integer() | nil
  def project_budget_reset_at(project) do
    case scope_config(project)["budget_reset_at"] do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc "Stamp `scope`'s budget as reset right now. `{:error, :not_found}` if an unknown project."
  @spec reset_project_budget(String.t() | nil) :: :ok | {:error, :not_found}
  def reset_project_budget(scope), do: update_scope(scope, %{"budget_reset_at" => System.system_time(:second)})

  @doc "Locale for fixed system messages (default \"en\")."
  def locale, do: load()["locale"] || "en"

  @doc "Set the locale and apply it to Gettext for this process."
  def set_locale(locale) do
    update(fn config -> config |> Map.put("locale", locale) end)
  end

  @doc "Apply the configured locale to `Pepe.Gettext` (call per process)."
  def put_locale, do: Gettext.put_locale(Pepe.Gettext, locale())

  ###
  ### Helpers
  ###

  @doc """
  Resolve a config value that points at a secret rather than holding one.

  Three forms, and the first is the one that has always been here:

    * `${ENV_VAR}` - an environment variable.
    * `exec:COMMAND` - whatever the command prints (`exec:op read op://Work/openai/key`).
    * `file:/path` - the contents of a file (a Docker or Kubernetes secret mount).

  Non-strings pass through untouched, and anything that resolves to nothing returns `nil` so
  callers treat it exactly as they already treat an unset variable.

  The last two are fetched at the point of use, by the runtime, and cached briefly
  (`Pepe.Secrets.Vault`). Which is the whole point of them: the secret is never in the config
  file, never in the environment, and never in anything the agent can read.
  """
  def interpolate(nil), do: nil

  def interpolate(value) when is_binary(value) do
    cond do
      Pepe.Secrets.Vault.ref?(value) ->
        Pepe.Secrets.Vault.resolve(value)

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

  @doc """
  Environment variables a vault resolver is allowed to see (`secrets.vault_env` in the
  config), on top of the bare minimum it needs to run at all.

  A 1Password service account needs `OP_SERVICE_ACCOUNT_TOKEN`; Vault needs `VAULT_ADDR` and
  `VAULT_TOKEN`. Naming them is the point: the resolver gets what it needs to open the vault,
  and not the rest of Pepe's environment on the way past.
  """
  @spec vault_env() :: [String.t()]
  def vault_env do
    case get_in(load(), ["secrets", "vault_env"]) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  # Models are id-keyed (unlike agents/projects, which are still name-keyed),
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

  # Like maybe_default/3 but only for the DEFAULT project's items: an agent/model in another
  # project must never become the global default just by being the first one created. A nil-scope
  # name (a bare handle, or a model id, which carries no project prefix) belongs to the default
  # project, so it counts.
  defp maybe_default_root(config, key, name) do
    slug = default_project_slug(config)
    if (Project.of(name) || slug) == slug, do: maybe_default(config, key, name), else: config
  end

  defp clear_default_if(config, key, name) do
    if config[key] == name, do: Map.put(config, key, nil), else: config
  end
end
