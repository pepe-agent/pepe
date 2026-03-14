defmodule PepeWeb.ToolServersLive do
  @moduledoc "Tool servers (MCP) section: external tool servers that extend agents."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

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
       edit_mcp: nil
     )}
  end

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
          desc={gettext("Give agents extra abilities from external tool servers - MCP (Sentry, GitHub, ...). Keep secrets safe by writing tokens as ${ENV_VAR}.")}
        >
          <button phx-click="mcp_new" class={btn()}>{gettext("+ New server")}</button>
        </.view_header>
        <div class="flex-1 space-y-3 overflow-y-auto p-6">
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
              {gettext("couldn't connect - check the command and the env var token")}
            </div>
          </div>
          <p :if={@mcp == %{}} class="text-[15px] text-zinc-500">{gettext("No MCP servers yet - add one below.")}</p>

          <form :if={@edit_mcp} phx-submit="mcp_save" class="space-y-4 rounded-xl border border-orange-900/60 bg-orange-950/10 p-5">
            <div class="text-[15px] font-medium">{gettext("+ New MCP server")}</div>
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input name="name" placeholder="sentry" class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("Command")}</label>
              <input name="command" value="npx" class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("Arguments")}</label>
              <input name="args" placeholder={"-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"} class={[fld(), "font-mono"]} />
              <p class={hlp()}>{gettext("Put the token as ${ENV_VAR} - the secret stays out of the config file.")}</p>
            </div>
            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="mcp_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("mcp_new", _p, socket), do: {:noreply, assign(socket, edit_mcp: %{})}
  def handle_event("mcp_cancel", _p, socket), do: {:noreply, assign(socket, edit_mcp: nil)}

  def handle_event("mcp_save", %{"name" => name, "command" => command, "args" => args}, socket) do
    name = String.trim(name)

    if name == "" or String.trim(command) == "" do
      {:noreply, put_flash(socket, :error, gettext("Name and command are required."))}
    else
      Config.put_mcp_server(name, %{
        "command" => String.trim(command),
        "args" => String.split(args, " ", trim: true),
        "env" => %{}
      })

      {:noreply,
       socket
       |> assign(mcp: Config.mcp_servers(), edit_mcp: nil)
       |> put_flash(:info, gettext("MCP server %{name} saved - validate it.", name: name))}
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
