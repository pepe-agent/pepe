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
       companies: Config.companies(),
       new_company: false,
       mcp: Config.mcp_servers(),
       mcp_tools: %{},
       edit_mcp: nil,
       form: mcp_form(%{"command" => "npx"})
     )}
  end

  defp mcp_changeset(attrs) do
    types = %{name: :string, command: :string, args: :string}

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:name, :command])
  end

  defp mcp_form(attrs), do: to_form(mcp_changeset(attrs), as: :mcp)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="mcp" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🧰"
          title="MCP"
          desc={gettext("Give agents extra abilities from external tool servers like MCP (Sentry, GitHub, ...). Keep secrets safe by writing tokens as ${ENV_VAR}.")}
        >
          <button :if={!@edit_mcp} phx-click="mcp_new" class={btn()}>{gettext("+ New server")}</button>
          <button :if={@edit_mcp} phx-click="mcp_cancel" class={btn_ghost()}>&larr; {gettext("Back to servers")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-6">
          <div :if={!@edit_mcp} class="space-y-3">
          <div :for={{name, cfg} <- @mcp} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <span class="font-medium">{name}</span>
              <div class="flex shrink-0 gap-1 text-sm">
                <button phx-click="mcp_validate" phx-value-name={name} class={btn_ghost()}>{gettext("Validate (list tools)")}</button>
                <button phx-click="mcp_remove" phx-value-name={name} data-confirm={gettext("Remove MCP server %{name}?", name: name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400"><code>{cfg["command"]} {Enum.join(cfg["args"] || [], " ")}</code></div>
            <div :if={@mcp_tools[name] == :loading} class={hlp()}>{gettext("connecting...")}</div>
            <div :if={is_list(@mcp_tools[name])} class="mt-2 space-y-1">
              <div :for={t <- @mcp_tools[name]} class="text-sm text-zinc-400">
                <code class="text-zinc-300">mcp__{name}__{t["name"]}</code>
                <span class="text-zinc-500">- {String.slice(to_string(t["description"]), 0, 90)}</span>
              </div>
              <p class="text-sm text-zinc-500">{gettext("Grant an agent only the read tools (Agents tab -> Tools) to keep it read-only.")}</p>
            </div>
            <div :if={match?({:error, _}, @mcp_tools[name])} class="mt-1 text-sm text-red-400">
              {gettext("couldn't connect. Check the command and the env var token")}
            </div>
          </div>
          <p :if={@mcp == %{}} class="text-[15px] text-zinc-500">{gettext("No MCP servers yet. Add one with “+ New server”.")}</p>
          </div>

          <div :if={@edit_mcp} class="max-w-2xl">
          <.form for={@form} phx-submit="mcp_save" phx-change="mcp_change" class="space-y-4">
            <div class="text-lg font-semibold">{gettext("+ New MCP server")}</div>
            <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
              {gettext("Please fix the errors below.")}
            </div>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="sentry" />
            <.input field={@form[:command]} label={gettext("Command")} />
            <div>
              <.input field={@form[:args]} label={gettext("Arguments")} class={[fld(), "font-mono"]}
                placeholder={"-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"} />
              <p class={hlp()}>{gettext("Put the token as ${ENV_VAR}. The secret stays out of the config file.")}</p>
            </div>
            <div class="flex gap-2 border-t border-zinc-800 pt-4">
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
    do: {:noreply, assign(socket, edit_mcp: %{}, form: mcp_form(%{"command" => "npx"}))}

  def handle_event("mcp_cancel", _p, socket), do: {:noreply, assign(socket, edit_mcp: nil)}

  def handle_event("mcp_change", %{"mcp" => p}, socket),
    do: {:noreply, assign(socket, form: to_form(%{mcp_changeset(p) | action: :validate}, as: :mcp))}

  def handle_event("mcp_save", %{"mcp" => p}, socket) do
    cs = mcp_changeset(p)

    if cs.valid? do
      name = Changeset.get_field(cs, :name)

      Config.put_mcp_server(name, %{
        "command" => String.trim(Changeset.get_field(cs, :command)),
        "args" => String.split(p["args"] || "", " ", trim: true),
        "env" => %{}
      })

      {:noreply,
       socket
       |> assign(mcp: Config.mcp_servers(), edit_mcp: nil)
       |> put_flash(:info, gettext("MCP server %{name} saved - validate it.", name: name))}
    else
      {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :mcp))}
    end
  end

  def handle_event("mcp_remove", %{"name" => name}, socket) do
    Config.delete_mcp_server(name)
    {:noreply, assign(socket, mcp: Config.mcp_servers())}
  end

  def handle_event("mcp_validate", %{"name" => name}, socket) do
    parent = self()
    Task.start(fn -> send(parent, {:mcp_validated, name, Pepe.MCP.tools(name)}) end)
    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, :loading))}
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/mcp")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  @impl true
  def handle_info({:mcp_validated, name, result}, socket) do
    value =
      case result do
        {:ok, tools} -> tools
        {:error, reason} -> {:error, reason}
      end

    {:noreply, update(socket, :mcp_tools, &Map.put(&1, name, value))}
  end
end
