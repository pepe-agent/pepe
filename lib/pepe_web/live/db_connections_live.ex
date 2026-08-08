defmodule PepeWeb.DbConnectionsLive do
  @moduledoc "Databases section: external Postgres connections for the db_query tool."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Config
  alias Pepe.DB

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Databases",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       connections: Config.db_connections(),
       edit_conn: nil,
       # Per-connection result of the "Test connection" button: :testing | :ok | {:error, msg}.
       checks: %{},
       # Only a real save attempt turns this on, so the top-level "fix the errors" banner
       # can't fire on the first keystroke of a field the operator hasn't finished typing
       # (the per-field errors below are gated by `used_input?` and stay hidden until then).
       submitted?: false,
       form: blank_form()
     )}
  end

  # `editing` is the name of the connection being edited, or nil for a new one: an edit
  # leaves Password blank to keep the stored secret, so it can't be required there.
  defp conn_changeset(attrs, editing) do
    types = %{
      name: :string,
      host: :string,
      port: :integer,
      database: :string,
      user: :string,
      password: :string,
      tenant_column: :string,
      tenant_mode: :string,
      tenant_value: :string
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required(required_fields(editing))
    |> Changeset.validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_tenant()
  end

  defp required_fields(nil), do: [:name, :host, :database, :user, :password]
  defp required_fields(_editing), do: [:name, :host, :database, :user]

  # A tenant_column with no mode/value would silently save an unscoped connection under a
  # scoped-looking name - require both together, same as the CLI and the manage_db tool.
  defp validate_tenant(changeset) do
    case Changeset.get_field(changeset, :tenant_column) do
      col when is_binary(col) and col != "" ->
        tenant_mode = Changeset.get_field(changeset, :tenant_mode)

        changeset
        |> Changeset.validate_required([:tenant_mode, :tenant_value])
        |> validate_tenant_mode(tenant_mode)

      _ ->
        changeset
    end
  end

  defp validate_tenant_mode(changeset, "agent_field") do
    if Changeset.get_field(changeset, :tenant_value) in ["project", "bare"] do
      changeset
    else
      Changeset.add_error(changeset, :tenant_value, gettext(~s(must be "project" or "bare" for agent_field mode)))
    end
  end

  defp validate_tenant_mode(changeset, "fixed"), do: changeset
  defp validate_tenant_mode(changeset, nil), do: changeset

  defp validate_tenant_mode(changeset, _mode),
    do: Changeset.add_error(changeset, :tenant_mode, gettext(~s(must be "fixed" or "agent_field")))

  defp conn_form(attrs, editing \\ nil), do: to_form(conn_changeset(attrs, editing), as: :conn)

  defp blank_form, do: conn_form(%{"tenant_mode" => "fixed"})

  defp tenant_scoped?(%{"tenant_column" => col}), do: is_binary(col) and col != ""
  defp tenant_scoped?(_cfg), do: false

  # The website's docs are published per language; send the operator to the page in the
  # language the dashboard itself is rendering in.
  defp docs_url(page) do
    lang =
      case Gettext.get_locale(Pepe.Gettext) do
        "pt_BR" -> "pt-br"
        "pt_PT" -> "pt-pt"
        "es" -> "es"
        _ -> "en"
      end

    "https://pepe-agent.com/#{lang}/docs/#{page}/"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="databases" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🗄️"
          title={gettext("Databases")}
          desc={gettext("Let an agent read from an external Postgres database with the db_query tool. Postgres is the only engine for now. The database's own Row-Level Security enforces tenant isolation, never a value the model supplies: the role and policy SQL to run once, by hand, is in the Database docs.")}
        >
          <.link href={docs_url("database")} target="_blank" rel="noopener" class={btn_ghost()}>{gettext("Database docs ↗")}</.link>
          <button :if={!@edit_conn} phx-click="conn_new" class={btn()}>{gettext("+ New connection")}</button>
          <button :if={@edit_conn} phx-click="conn_cancel" class={btn_ghost()}>&larr; {gettext("Back to connections")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div :if={!@edit_conn} class="space-y-3">
          <div :for={{name, cfg} <- @connections} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span class="font-medium">{name}</span>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                <button phx-click="conn_test" phx-value-name={name} class={btn_ghost()}>{gettext("Test connection")}</button>
                <button phx-click="conn_edit" phx-value-name={name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button phx-click="conn_remove" phx-value-name={name} data-confirm={gettext("Remove database connection %{name}?", name: name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">
              <code>{cfg["user"]}@{cfg["host"]}:{cfg["port"] || 5432}/{cfg["database"]}</code>
            </div>
            <div class="mt-1 text-sm">
              <span :if={tenant_scoped?(cfg)} class="text-emerald-400">✓ {gettext("tenant-scoped on %{col}", col: cfg["tenant_column"])}</span>
              <span :if={!tenant_scoped?(cfg)} class="text-amber-400">{gettext("unscoped (no per-tenant isolation)")}</span>
            </div>
            <div :if={@checks[name]} class="mt-1 text-sm">
              <span :if={@checks[name] == :testing} class="text-zinc-500">{gettext("Connecting...")}</span>
              <span :if={@checks[name] == :ok} class="text-emerald-400">✓ {gettext("Connected. The credentials work.")}</span>
              <span :if={match?({:error, _}, @checks[name])} class="text-red-400">
                {gettext("Could not connect:")} {elem(@checks[name], 1)}
              </span>
            </div>
          </div>
          <.empty_state :if={@connections == %{}}>
            {gettext("No database connections yet. Add one with “+ New connection”.")}
          </.empty_state>
          </div>

          <div :if={@edit_conn} class="max-w-2xl">
          <.form id="db-form" for={@form} phx-submit="conn_save" phx-change="conn_change" class="space-y-4">
            <div class="text-lg font-semibold">
              {if @edit_conn[:name], do: gettext("Edit %{name}", name: @edit_conn[:name]), else: gettext("+ New database connection")}
            </div>
            <div :if={@submitted? && @form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <.form_section title={gettext("Connection")}>
              <div>
                <.input field={@form[:name]} label={gettext("Name")} placeholder="billing_prod" />
                <p :if={@edit_conn[:name]} class={hlp()}>{gettext("Renaming saves this under the new name and drops the old one. Anything pointing at the old name has to be updated by hand.")}</p>
              </div>
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input field={@form[:host]} label={gettext("Host")} placeholder="db.internal" />
                <.input field={@form[:port]} type="number" min="1" max="65535" label={gettext("Port")} placeholder="5432" />
              </div>
              <.input field={@form[:database]} label={gettext("Database")} />
              <.input field={@form[:user]} label={gettext("User")} placeholder="pepe_ro" />
              <div>
                <.input field={@form[:password]} type="password" label={gettext("Password")} class={[fld(), "font-mono"]} placeholder="${DB_PASSWORD}" />
                <p :if={@edit_conn[:name]} class={hlp()}>{gettext("Leave blank to keep the password already saved.")}</p>
                <p class={hlp()}>{gettext("Put it as ${ENV_VAR}. The secret stays out of the config file.")}</p>
              </div>
            </.form_section>

            <.form_section title={gettext("Tenant isolation")}>
              <div>
                <.input field={@form[:tenant_column]} label={gettext("Tenant column (optional)")} placeholder="company_id" />
                <p class={hlp()}>{gettext("Leave empty for an unscoped connection. Set this only if the database enforces isolation on this column with Row-Level Security.")}</p>
              </div>
              <div :if={@form[:tenant_column].value not in [nil, ""]} class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input
                  field={@form[:tenant_mode]}
                  type="select"
                  label={gettext("Tenant mode")}
                  options={[{gettext("Fixed value"), "fixed"}, {gettext("From the calling agent"), "agent_field"}]}
                />
                <div>
                  <.input :if={@form[:tenant_mode].value == "agent_field"} field={@form[:tenant_value]} type="select" label={gettext("Agent field")}
                    options={[{gettext("project"), "project"}, {gettext("bare"), "bare"}]} />
                  <.input :if={@form[:tenant_mode].value != "agent_field"} field={@form[:tenant_value]} label={gettext("Tenant value")} placeholder="acme-inc" />
                </div>
              </div>
            </.form_section>

            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="conn_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("conn_new", _p, socket),
    do: {:noreply, assign(socket, edit_conn: %{}, submitted?: false, form: blank_form())}

  def handle_event("conn_edit", %{"name" => name}, socket) do
    case socket.assigns.connections[name] do
      nil ->
        {:noreply, socket}

      cfg ->
        {:noreply,
         assign(socket,
           edit_conn: %{name: name},
           submitted?: false,
           # The stored password is never loaded back into the form: it stays where it is
           # unless the operator types a replacement (see `resolved_password/2`).
           form: conn_form(edit_attrs(name, cfg), name)
         )}
    end
  end

  def handle_event("conn_cancel", _p, socket),
    do: {:noreply, assign(socket, edit_conn: nil, submitted?: false)}

  def handle_event("conn_change", %{"conn" => p}, socket) do
    cs = conn_changeset(p, editing(socket))
    {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :conn))}
  end

  def handle_event("conn_save", %{"conn" => p}, socket) do
    editing = editing(socket)
    cs = conn_changeset(p, editing)

    if cs.valid? do
      name = Changeset.get_field(cs, :name)
      definition = build_definition(cs, editing)
      Config.put_db_connection(name, definition)
      if editing && editing != name, do: Config.delete_db_connection(editing)
      # Credentials only take effect on a fresh Postgrex connection - the cached one is
      # still holding the old ones (Pepe.DB has no push-based reconfiguration).
      if editing, do: recycle([editing, name])

      {:noreply,
       socket
       |> assign(connections: Config.db_connections(), edit_conn: nil, submitted?: false)
       |> update(:checks, &Map.drop(&1, [editing, name]))
       |> put_flash(:info, save_flash(name, definition))}
    else
      {:noreply, assign(socket, submitted?: true, form: to_form(%{cs | action: :validate}, as: :conn))}
    end
  end

  def handle_event("conn_remove", %{"name" => name}, socket) do
    Config.delete_db_connection(name)

    {:noreply,
     socket
     |> assign(connections: Config.db_connections())
     |> update(:checks, &Map.delete(&1, name))}
  end

  # Opens a real connection and runs the cheapest possible query on it, off the LiveView
  # process so a host that never answers doesn't freeze the page.
  def handle_event("conn_test", %{"name" => name}, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:conn_tested, name, ping(name)}) end)
    {:noreply, update(socket, :checks, &Map.put(&1, name, :testing))}
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/databases")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  @impl true
  def handle_info({:conn_tested, name, result}, socket),
    do: {:noreply, update(socket, :checks, &Map.put(&1, name, result))}

  defp editing(socket), do: socket.assigns.edit_conn[:name]

  defp edit_attrs(name, cfg) do
    binding = cfg["tenant_binding"] || %{}

    %{
      "name" => name,
      "host" => cfg["host"],
      "port" => cfg["port"] || 5432,
      "database" => cfg["database"],
      "user" => cfg["user"],
      "password" => "",
      "tenant_column" => cfg["tenant_column"],
      "tenant_mode" => binding["mode"] || "fixed",
      "tenant_value" => binding["value"]
    }
  end

  defp ping(name) do
    with {:ok, pid} <- DB.ensure(name),
         {:ok, _result} <- Postgrex.query(pid, "SELECT 1", []) do
      :ok
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  catch
    # A connection that dies mid-query exits the caller; this Task is the caller, and it
    # still has to report something back or the card sits on "Connecting..." forever.
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  defp failure(reason) when is_exception(reason), do: Exception.message(reason)
  defp failure(reason), do: inspect(reason)

  defp recycle(names), do: Enum.each(Enum.uniq(names), &DB.restart/1)

  # Merged over whatever is already stored, so an edit through this form can't drop the
  # keys it doesn't render (a connection's project/agent scoping).
  defp build_definition(cs, editing) do
    base = (editing && Config.db_connections()[editing]) || %{}

    Map.merge(base, %{
      "engine" => "postgres",
      "host" => Changeset.get_field(cs, :host),
      "port" => port(Changeset.get_field(cs, :port)),
      "database" => Changeset.get_field(cs, :database),
      "user" => Changeset.get_field(cs, :user),
      "password" => resolved_password(cs, editing),
      "tenant_column" => Changeset.get_field(cs, :tenant_column),
      "tenant_binding" => tenant_binding(cs)
    })
  end

  # Blank on an edit means "keep what's saved" - the form never shows the stored secret,
  # so an empty field is the operator not touching it, not the operator clearing it.
  defp resolved_password(cs, editing) do
    case Changeset.get_field(cs, :password) do
      pw when is_binary(pw) and pw != "" -> pw
      _ -> editing && Config.db_connections()[editing]["password"]
    end
  end

  defp tenant_binding(cs) do
    case Changeset.get_field(cs, :tenant_column) do
      col when is_binary(col) and col != "" ->
        %{"mode" => Changeset.get_field(cs, :tenant_mode), "value" => Changeset.get_field(cs, :tenant_value)}

      _ ->
        nil
    end
  end

  # Only ever reached with a valid changeset: a port that didn't parse as an integer is a
  # cast error on the field, not something to quietly turn into 5432.
  defp port(nil), do: 5432
  defp port(n) when is_integer(n), do: n

  defp save_flash(name, %{"tenant_column" => col}) when is_binary(col) and col != "" do
    gettext(
      "Database connection %{name} saved, tenant-scoped on %{col}. This protects nothing on its own: make sure Row-Level Security is set up on the database itself.",
      name: name,
      col: col
    )
  end

  defp save_flash(name, _definition), do: gettext("Database connection %{name} saved.", name: name)
end
