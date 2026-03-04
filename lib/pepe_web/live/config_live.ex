defmodule PepeWeb.ConfigLive do
  @moduledoc """
  The raw config-file editor: show `~/.pepe/config.json`, let the operator edit it,
  and save it back - validated as JSON first, so a broken file can't be written.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Config",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       config_text: read_config()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="config" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="⚙️"
          title={gettext("Configuration file")}
          desc={gettext("The raw config.json the runtime reads. Edit and save - it's validated as JSON first, so a broken file is refused. Secrets stay as ${ENV_VAR} references, resolved at read time (never stored raw).")}
        >
          <button phx-click="config_reload" class={btn_ghost()}>{gettext("Reload from disk")}</button>
        </.view_header>

        <div class="flex min-h-0 flex-1 flex-col gap-3 p-6">
          <form phx-submit="config_save" class="flex min-h-0 flex-1 flex-col gap-3">
            <textarea
              name="json"
              spellcheck="false"
              class="min-h-0 w-full flex-1 resize-none rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-xs leading-relaxed text-zinc-100 outline-none focus:border-orange-500 focus:ring-1 focus:ring-orange-500"
            >{@config_text}</textarea>
            <div class="flex items-center gap-3">
              <button type="submit" class={btn()}>{gettext("Save config")}</button>
              <span class="text-xs text-zinc-500">
                {gettext("Saving replaces the whole file. Invalid JSON is rejected.")}
              </span>
            </div>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("config_save", %{"json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        Config.save(map)
        Pepe.Gateways.Supervisor.reload_telegram()

        {:noreply,
         socket
         |> assign(config_text: pretty(map), companies: Config.companies())
         |> put_flash(:info, gettext("Config saved."))}

      {:ok, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("The top level must be a JSON object { ... }."))}

      {:error, err} ->
        {:noreply,
         put_flash(socket, :error, gettext("Invalid JSON: %{msg}", msg: Exception.message(err)))}
    end
  end

  def handle_event("config_reload", _p, socket) do
    {:noreply, assign(socket, config_text: read_config())}
  end

  # Shared sidebar events. The workspace scope drives agents/models, so changing it
  # jumps to that scope's Agents; creating a company does the same.
  def handle_event("set_scope", %{"scope" => scope}, socket) do
    {:noreply, push_navigate(socket, to: "/agents?scope=#{scope}")}
  end

  def handle_event("toggle_new_company", _p, socket) do
    {:noreply, assign(socket, new_company: !socket.assigns.new_company)}
  end

  def handle_event("company_add", %{"name" => name}, socket) do
    name = String.trim(name)

    case Config.add_company(name) do
      :ok -> {:noreply, push_navigate(socket, to: "/agents?scope=#{name}")}
      _ -> {:noreply, put_flash(socket, :error, gettext("Invalid or duplicate company name."))}
    end
  end

  defp read_config do
    case File.read(Config.path()) do
      {:ok, body} -> body
      _ -> pretty(Config.load())
    end
  end

  defp pretty(map), do: Jason.encode!(map, pretty: true)
end
