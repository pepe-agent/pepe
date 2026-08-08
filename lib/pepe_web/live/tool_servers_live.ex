defmodule PepeWeb.ToolServersLive do
  @moduledoc "Tool servers (MCP) section: external tool servers that extend agents."
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
       page_title: "Pepe · MCP",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       mcp: Config.mcp_servers(),
       mcp_tools: %{},
       edit_mcp: nil,
       login: nil,
       submitted?: false,
       form: blank_form()
     )}
  end

  defp mcp_changeset(attrs) do
    types = %{
      name: :string,
      kind: :string,
      command: :string,
      args: :string,
      url: :string,
      headers: :string,
      transport: :string
    }

    changeset =
      {%{}, types}
      |> Changeset.cast(attrs, Map.keys(types))
      |> Changeset.validate_required([:name])

    # A server is one kind or the other, and the field that matters is the one its kind
    # names - requiring both would make every remote server fail on a missing command.
    case Changeset.get_field(changeset, :kind) do
      "remote" -> Changeset.validate_required(changeset, [:url])
      _ -> Changeset.validate_required(changeset, [:command])
    end
  end

  defp mcp_form(attrs), do: to_form(mcp_changeset(attrs), as: :mcp)

  defp blank_form,
    do: mcp_form(%{"kind" => "remote", "command" => "npx", "transport" => "auto"})

  # An existing definition back into the flat, string-keyed shape the form edits.
  defp edit_attrs(name, cfg) do
    remote? = is_binary(cfg["url"]) and cfg["url"] != ""

    %{
      "name" => name,
      "kind" => if(remote?, do: "remote", else: "local"),
      "url" => cfg["url"] || "",
      "transport" => cfg["transport"] || "auto",
      "headers" => unparse_headers(cfg["headers"]),
      "command" => cfg["command"] || "npx",
      "args" => Enum.join(cfg["args"] || [], " ")
    }
  end

  # The labels are here rather than in Pepe.MCP.Transport because they are gettext strings,
  # but the values come from there - an unlabelled future choice still shows up, as itself,
  # instead of crashing the form.
  defp transport_options do
    Enum.map(Pepe.MCP.Transport.choices(), fn
      "auto" -> {gettext("Auto (recommended)"), "auto"}
      "streamable" -> {gettext("Streamable HTTP"), "streamable"}
      "sse" -> {gettext("HTTP+SSE (legacy)"), "sse"}
      other -> {other, other}
    end)
  end

  defp transport_value(value) do
    if value in Pepe.MCP.Transport.choices(), do: value, else: "auto"
  end

  # "Key: value" per line, split on the first colon only (a value is routinely a URL or a
  # scheme-prefixed credential with colons of its own).
  defp parse_headers(text) do
    (text || "")
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] when key != "" -> [{String.trim(key), String.trim(value)}]
        _ -> []
      end
    end)
    |> Enum.into(%{})
  end

  defp unparse_headers(headers) when is_map(headers) do
    headers |> Enum.map(fn {key, value} -> "#{key}: #{value}" end) |> Enum.join("\n")
  end

  defp unparse_headers(_), do: ""

  defp put_kept(definition, previous, key) do
    case previous[key] do
      nil -> definition
      empty when empty == %{} -> definition
      value -> Map.put(definition, key, value)
    end
  end

  defp auth_state(name, cfg) do
    cond do
      map_size(cfg["headers"] || %{}) > 0 -> :header
      Pepe.MCP.OAuth.credential(name) -> :oauth
      true -> :none
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="mcp" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🧰"
          title="MCP"
          desc={gettext("Give agents extra tools from external MCP servers (Sentry, GitHub, ...). Write tokens as ${ENV_VAR} to keep secrets out of the config file.")}
        >
          <button :if={!@edit_mcp} phx-click="mcp_new" class={btn()}>{gettext("+ New server")}</button>
          <button :if={@edit_mcp} phx-click="mcp_cancel" class={btn_ghost()}>&larr; {gettext("Back to servers")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div :if={!@edit_mcp} class="space-y-3">
          <div :for={{name, cfg} <- @mcp} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <span class="font-medium">{name}</span>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                <button phx-click="mcp_edit" phx-value-name={name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button phx-click="mcp_validate" phx-value-name={name} class={btn_ghost()}>{gettext("Validate (list tools)")}</button>
                <button phx-click="mcp_restart" phx-value-name={name} class={btn_ghost()} title={gettext("Recovery: reconnect if this server seems stuck")}>↻ {gettext("Restart")}</button>
                <button phx-click="mcp_remove" phx-value-name={name} data-confirm={gettext("Remove MCP server %{name}?", name: name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div :if={cfg["url"]} class="mt-1 text-sm text-zinc-400">
              <code>{cfg["url"]}</code>
              <span class="text-zinc-500">· {cfg["transport"] || "auto"}</span>
            </div>
            <div :if={!cfg["url"]} class="mt-1 text-sm text-zinc-400"><code>{cfg["command"]} {Enum.join(cfg["args"] || [], " ")}</code></div>
            <div :if={cfg["url"]} class="mt-2 flex flex-wrap items-center gap-2 text-sm">
              <span :if={auth_state(name, cfg) == :header} class="text-zinc-500">🔑 {gettext("Static key from a header")}</span>
              <span :if={auth_state(name, cfg) == :oauth} class="text-emerald-400">✓ {gettext("Signed in with OAuth")}</span>
              <span :if={auth_state(name, cfg) == :none} class="text-amber-400">{gettext("No credential")}</span>
              <button :if={auth_state(name, cfg) != :header} phx-click="mcp_login" phx-value-name={name} class={btn_ghost()}>
                {if auth_state(name, cfg) == :oauth, do: gettext("Sign in again"), else: gettext("Sign in with OAuth")}
              </button>
              <button :if={auth_state(name, cfg) == :oauth} phx-click="mcp_logout" phx-value-name={name} class={btn_ghost()}>{gettext("Sign out")}</button>
            </div>
            <div :if={@login && @login.server == name} class="mt-2 space-y-2 rounded-lg border border-zinc-800 bg-zinc-900/60 p-3">
              <p class="text-sm text-zinc-300">{gettext("Open this link to authorize, then come back:")}</p>
              <a href={@login.url} target="_blank" rel="noopener" class="block break-all text-sm text-sky-400 hover:underline">{@login.url}</a>
              <form phx-submit="mcp_login_code">
                <label for={"mcp-code-" <> name} class={lbl()}>{gettext("Authorization code")}</label>
                <div class="flex flex-wrap gap-2">
                  <input id={"mcp-code-" <> name} name="code" placeholder={gettext("paste code here")} class={[fld(), "min-w-0 flex-1"]} />
                  <button type="submit" class={btn()}>{gettext("Finish")}</button>
                </div>
                <p class={hlp()}>{gettext("Only needed if the browser can't reach this machine. Otherwise it fills itself in.")}</p>
              </form>
            </div>
            <div :if={@mcp_tools[name] == :loading} class={hlp()}>{gettext("Connecting...")}</div>
            <div :if={is_list(@mcp_tools[name])} class="mt-2 space-y-1">
              <div :for={t <- @mcp_tools[name]} class="text-sm text-zinc-400">
                <code class="text-zinc-300">mcp__{name}__{t["name"]}</code>
                <span class="text-zinc-500">- {String.slice(to_string(t["description"]), 0, 90)}</span>
              </div>
              <p class="text-sm text-zinc-500">{gettext("Grant an agent only the read tools (Agents tab -> Tools) to keep it read-only.")}</p>
            </div>
            <div :if={match?({:error, _}, @mcp_tools[name])} class="mt-1 text-sm text-red-400">
              {gettext("Couldn't connect. Check the command and the env var token")}
            </div>
          </div>
          <p :if={@mcp == %{}} class="text-[15px] text-zinc-500">{gettext("No MCP servers yet. Add one with “+ New server”.")}</p>
          </div>

          <div :if={@edit_mcp} class="max-w-2xl">
          <.form id="mcp-form" for={@form} phx-submit="mcp_save" phx-change="mcp_change" class="space-y-6">
            <div class="text-lg font-semibold">
              {if @edit_mcp[:original], do: gettext("Edit MCP server"), else: gettext("+ New MCP server")}
            </div>
            <div :if={@submitted? && @form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>

            <.form_section title={gettext("Server")}>
              <div>
                <.input field={@form[:name]} label={gettext("Name")} placeholder="sentry" />
                <p :if={@edit_mcp[:original]} class={hlp()}>
                  {gettext("Renaming saves this as a new server. An OAuth sign-in is tied to the name, so it has to be done again.")}
                </p>
              </div>
              <.input
                field={@form[:kind]}
                type="select"
                label={gettext("Kind")}
                options={[{gettext("Remote (a URL over HTTP)"), "remote"}, {gettext("Local (a command on this machine)"), "local"}]}
              />
              <.input :if={@form[:kind].value != "local"} field={@form[:url]} label={gettext("URL")} class={[fld(), "font-mono"]} placeholder="https://mcp.example.com/mcp" />
              <div :if={@form[:kind].value != "local"}>
                <.input field={@form[:transport]} type="select" label={gettext("Transport")} options={transport_options()} />
                <p class={hlp()}>{gettext("Auto tries the modern protocol and falls back on its own. Pin one only for a server that answers a single one.")}</p>
              </div>
              <div :if={@form[:kind].value == "local"}>
                <.input field={@form[:command]} label={gettext("Command")} class={[fld(), "font-mono"]} placeholder="npx" />
                <p class={hlp()}>{gettext("The executable to run, e.g. npx, uvx, python.")}</p>
              </div>
              <div :if={@form[:kind].value == "local"}>
                <.input field={@form[:args]} label={gettext("Arguments")} class={[fld(), "font-mono"]}
                  placeholder={"-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"} />
                <p class={hlp()}>{gettext("Put the token as ${ENV_VAR}. The secret stays out of the config file.")}</p>
              </div>
            </.form_section>

            <.form_section :if={@form[:kind].value != "local"} title={gettext("Authentication")}>
              <p class="text-[15px] leading-relaxed text-zinc-400">
                {gettext("Two ways in, pick one. Most hosted servers use OAuth: leave Headers empty, save, then press “Sign in with OAuth” on the server's card. A server that hands out a fixed token instead wants that token as a header below.")}
              </p>
              <div>
                <.input field={@form[:headers]} type="textarea" label={gettext("Headers (only for a fixed token)")} class={[fld(), "font-mono"]}
                  placeholder={"Authorization: Bearer ${MCP_TOKEN}"} />
                <p class={hlp()}>{gettext("One per line, as Key: value. Write the token as ${ENV_VAR} so the secret stays out of the config file.")}</p>
              </div>
            </.form_section>

            <div class="flex gap-2">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="mcp_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("mcp_new", _p, socket),
    do: {:noreply, assign(socket, edit_mcp: %{original: nil}, submitted?: false, form: blank_form())}

  def handle_event("mcp_edit", %{"name" => name}, socket) do
    case socket.assigns.mcp[name] do
      nil ->
        {:noreply, socket}

      cfg ->
        {:noreply,
         assign(socket,
           edit_mcp: %{original: name},
           submitted?: false,
           login: nil,
           form: mcp_form(edit_attrs(name, cfg))
         )}
    end
  end

  def handle_event("mcp_cancel", _p, socket),
    do: {:noreply, assign(socket, edit_mcp: nil, submitted?: false)}

  def handle_event("mcp_change", %{"mcp" => p}, socket),
    do: {:noreply, assign(socket, form: to_form(%{mcp_changeset(p) | action: :validate}, as: :mcp))}

  def handle_event("mcp_save", %{"mcp" => p}, socket) do
    cs = mcp_changeset(p)
    original = socket.assigns.edit_mcp[:original]

    if cs.valid? do
      name = String.trim(Changeset.get_field(cs, :name))
      # Whatever this form has no control over (a pinned OAuth client identity, a local
      # server's env) survives an edit instead of being dropped by the rewrite.
      previous = (original && socket.assigns.mcp[original]) || %{}

      definition =
        if Changeset.get_field(cs, :kind) == "remote" do
          %{
            "url" => String.trim(Changeset.get_field(cs, :url)),
            "headers" => parse_headers(p["headers"]),
            "transport" => transport_value(Changeset.get_field(cs, :transport))
          }
          |> put_kept(previous, "oauth")
        else
          %{
            "command" => String.trim(Changeset.get_field(cs, :command)),
            "args" => String.split(p["args"] || "", " ", trim: true),
            "env" => previous["env"] || %{}
          }
        end

      if original && original != name, do: Config.delete_mcp_server(original)
      Config.put_mcp_server(name, definition)

      # A client already connected under the old definition would keep serving it until
      # something restarted it. Both names, so a rename doesn't strand the old one.
      if original, do: Enum.each(Enum.uniq([original, name]), &Pepe.MCP.restart/1)

      {:noreply,
       socket
       |> assign(mcp: Config.mcp_servers(), edit_mcp: nil, submitted?: false)
       |> update(:mcp_tools, &Map.drop(&1, [original, name]))
       |> put_flash(:info, gettext("MCP server %{name} saved. Validate it.", name: name))}
    else
      {:noreply, assign(socket, submitted?: true, form: to_form(%{cs | action: :validate}, as: :mcp))}
    end
  end

  def handle_event("mcp_remove", %{"name" => name}, socket) do
    Config.delete_mcp_server(name)
    {:noreply, assign(socket, mcp: Config.mcp_servers())}
  end

  def handle_event("mcp_login", %{"name" => name}, socket) do
    case Pepe.MCP.OAuth.begin(name, self()) do
      {:ok, session, url} ->
        {:noreply, assign(socket, login: %{server: name, url: url, session: session})}

      {:error, :mcp_no_registration_endpoint} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This server's authorization server doesn't allow dynamic registration. Pin a client_id in config.json.")
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't start sign-in: %{reason}", reason: inspect(reason)))}
    end
  end

  def handle_event("mcp_login_code", %{"code" => code}, socket) when code != "" do
    {:noreply, complete_login(socket, Pepe.OAuth.extract_code(code))}
  end

  def handle_event("mcp_login_code", _p, socket), do: {:noreply, socket}

  def handle_event("mcp_logout", %{"name" => name}, socket) do
    Pepe.MCP.OAuth.logout(name)
    Pepe.MCP.restart(name)

    {:noreply,
     socket
     |> assign(mcp: Config.mcp_servers())
     |> put_flash(:info, gettext("Signed out of %{name}.", name: name))}
  end

  def handle_event("mcp_restart", %{"name" => name}, socket) do
    Pepe.MCP.restart(name)

    {:noreply,
     socket
     |> update(:mcp_tools, &Map.delete(&1, name))
     |> put_flash(:info, gettext("MCP server %{name} restarted (reconnects on next use).", name: name))}
  end

  def handle_event("mcp_validate", %{"name" => name}, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:mcp_validated, name, Pepe.MCP.tools(name)}) end)
    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, :loading))}
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/mcp")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  @impl true
  # The browser came back to the loopback callback on its own - no pasting needed.
  def handle_info({:oauth_code, _ref, code}, socket),
    do: {:noreply, complete_login(socket, code)}

  def handle_info({:oauth_error, _ref, reason}, socket) do
    {:noreply,
     socket
     |> assign(login: nil)
     |> put_flash(:error, gettext("Sign-in failed: %{reason}", reason: inspect(reason)))}
  end

  def handle_info({:mcp_validated, name, result}, socket) do
    value =
      case result do
        {:ok, tools} -> tools
        {:error, reason} -> {:error, reason}
      end

    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, value))}
  end

  defp complete_login(%{assigns: %{login: nil}} = socket, _code), do: socket

  defp complete_login(%{assigns: %{login: login}} = socket, code) do
    case Pepe.MCP.OAuth.finish(login.session, code) do
      {:ok, _credential} ->
        # Drop any client already connected without the token, so the next use reconnects
        # with it instead of staying unauthorized until something restarts.
        Pepe.MCP.restart(login.server)

        socket
        |> assign(login: nil, mcp: Config.mcp_servers())
        |> put_flash(:info, gettext("Signed in to %{name}.", name: login.server))

      {:error, reason} ->
        socket
        |> assign(login: nil)
        |> put_flash(:error, gettext("Sign-in failed: %{reason}", reason: inspect(reason)))
    end
  end
end
