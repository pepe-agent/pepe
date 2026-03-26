defmodule PepeWeb.IntegrationsLive do
  @moduledoc """
  Integrations section: connect *plugin* channel providers (Chatwoot, ...) to your
  agents. Built-in channels (Slack, Discord, Teams, Google Chat, WhatsApp) live on the
  Channels page; this page lists only providers that arrived as installed plugins. The
  connection UI itself is the shared `PepeWeb.ConnectionsComponent`, which renders each
  provider's form generically from its `config_schema/0`, so a new plugin needs no new
  screen.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Integrations",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       providers: plugin_channel_cards()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="integrations" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔌"
          title={gettext("Integrations")}
          desc={gettext("Connect channel plugins to your agents. Each provider's fields come from the plugin itself; fill them in, then paste the webhook URL into the provider.")}
        />

        <div class="min-h-0 flex-1 overflow-y-auto p-6">
          <div :if={@providers == []} class="max-w-3xl rounded-xl border border-dashed border-zinc-800 p-10 text-center text-zinc-500">
            <p>{gettext("No channel plugins installed yet.")}</p>
            <p class="mt-2">
              {gettext("Install one, then reload this page:")}
              <code class="text-zinc-300">mix pepe plugin install</code>
            </p>
            <p class="mt-1 text-sm text-zinc-600">{gettext("Built-in channels (Slack, Discord, Teams, Google Chat) live under Channels.")}</p>
          </div>

          <div :if={@providers != []} class="max-w-3xl">
            <.live_component
              module={PepeWeb.ConnectionsComponent}
              id="plugin-channels"
              providers={@providers}
              scope={@scope}
              companies={@companies}
            />
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/integrations")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  @impl true
  def handle_info({:flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:channel_form, _}, socket), do: {:noreply, socket}
end
