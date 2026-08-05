defmodule PepeWeb.DbConnectionsLive do
  @moduledoc "Databases section: external Postgres connections for the db_query tool."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Config

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
       form: blank_form()
     )}
  end

  defp conn_changeset(attrs) do
    types = %{
      name: :string,
      host: :string,
      port: :string,
      database: :string,
      user: :string,
      password: :string,
      tenant_column: :string,
      tenant_mode: :string,
      tenant_value: :string
    }

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:name, :host, :database, :user, :password])
    |> validate_tenant()
  end

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

  defp conn_form(attrs), do: to_form(conn_changeset(attrs), as: :conn)

  defp blank_form, do: conn_form(%{"tenant_mode" => "fixed"})

  defp tenant_scoped?(%{"tenant_column" => col}), do: is_binary(col) and col != ""
  defp tenant_scoped?(_cfg), do: false

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
          desc={gettext("Let an agent read from an external Postgres database with the db_query tool. A customer's own multi-tenancy is enforced by the database's own Row-Level Security, never by a value the model supplies - see the Database docs for the role/policy SQL to run once, by hand.")}
        >
          <button :if={!@edit_conn} phx-click="conn_new" class={btn()}>{gettext("+ New connection")}</button>
          <button :if={@edit_conn} phx-click="conn_cancel" class={btn_ghost()}>&larr; {gettext("Back to connections")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div :if={!@edit_conn} class="space-y-3">
          <div :for={{name, cfg} <- @connections} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span class="font-medium">{name}</span>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
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
          </div>
          <p :if={@connections == %{}} class="text-[15px] text-zinc-500">{gettext("No database connections yet. Add one with “+ New connection”.")}</p>
          </div>

          <div :if={@edit_conn} class="max-w-2xl">
          <.form id="db-form" for={@form} phx-submit="conn_save" phx-change="conn_change" class="space-y-4">
            <div class="text-lg font-semibold">{gettext("+ New database connection")}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>
            <p class={hlp()}>{gettext("Postgres only for now.")}</p>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="clientes_prod" />
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.input field={@form[:host]} label={gettext("Host")} placeholder="db.internal" />
              <.input field={@form[:port]} label={gettext("Port")} placeholder="5432" />
            </div>
            <.input field={@form[:database]} label={gettext("Database")} />
            <.input field={@form[:user]} label={gettext("User")} placeholder="pepe_ro" />
            <div>
              <.input field={@form[:password]} type="password" label={gettext("Password")} class={[fld(), "font-mono"]} placeholder="${DB_PASSWORD}" />
              <p class={hlp()}>{gettext("Put it as ${ENV_VAR}. The secret stays out of the config file.")}</p>
            </div>

            <div class="border-t border-zinc-800 pt-4">
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

            <div class="flex gap-2 border-t border-zinc-800 pt-4">
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
    do: {:noreply, assign(socket, edit_conn: %{}, form: blank_form())}

  def handle_event("conn_cancel", _p, socket), do: {:noreply, assign(socket, edit_conn: nil)}

  def handle_event("conn_change", %{"conn" => p}, socket),
    do: {:noreply, assign(socket, form: to_form(%{conn_changeset(p) | action: :validate}, as: :conn))}

  def handle_event("conn_save", %{"conn" => p}, socket) do
    cs = conn_changeset(p)

    if cs.valid? do
      name = Changeset.get_field(cs, :name)
      definition = build_definition(cs)
      Config.put_db_connection(name, definition)

      {:noreply,
       socket
       |> assign(connections: Config.db_connections(), edit_conn: nil)
       |> put_flash(:info, save_flash(name, definition))}
    else
      {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :conn))}
    end
  end

  def handle_event("conn_remove", %{"name" => name}, socket) do
    Config.delete_db_connection(name)
    {:noreply, assign(socket, connections: Config.db_connections())}
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/databases")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp build_definition(cs) do
    %{
      "engine" => "postgres",
      "host" => Changeset.get_field(cs, :host),
      "port" => port(Changeset.get_field(cs, :port)),
      "database" => Changeset.get_field(cs, :database),
      "user" => Changeset.get_field(cs, :user),
      "password" => Changeset.get_field(cs, :password),
      "tenant_column" => Changeset.get_field(cs, :tenant_column),
      "tenant_binding" => tenant_binding(cs)
    }
  end

  defp tenant_binding(cs) do
    case Changeset.get_field(cs, :tenant_column) do
      col when is_binary(col) and col != "" ->
        %{"mode" => Changeset.get_field(cs, :tenant_mode), "value" => Changeset.get_field(cs, :tenant_value)}

      _ ->
        nil
    end
  end

  defp port(nil), do: 5432
  defp port(""), do: 5432

  defp port(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 5432
    end
  end

  defp save_flash(name, %{"tenant_column" => col}) when is_binary(col) and col != "" do
    gettext(
      "Database connection %{name} saved, tenant-scoped on %{col}. This protects nothing on its own - make sure Row-Level Security is set up on the database itself.",
      name: name,
      col: col
    )
  end

  defp save_flash(name, _definition), do: gettext("Database connection %{name} saved.", name: name)
end
