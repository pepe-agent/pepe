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
       projects: Config.project_slugs(),
       new_project: false,
       config_text: read_config(),
       locale: Config.locale(),
       locales: Config.locales(),
       # nil = not checked yet · :checking · :up_to_date · a version string when newer.
       update: nil,
       can_self_update: not Pepe.Update.running_from_source?()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="config" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="⚙️"
          title={gettext("Configuration file")}
          desc={gettext("The raw config.json the runtime reads. Edit and save; it's validated as JSON first, so a broken file is refused. Secrets stay as ${ENV_VAR} references, resolved at read time (never stored raw).")}
        >
          <form phx-change="set_locale" class="flex items-center gap-2">
            <label for="locale" class="text-sm text-zinc-400">{gettext("Language")}</label>
            <select
              id="locale"
              name="locale"
              class="rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100"
            >
              <option :for={{code, label} <- @locales} value={code} selected={code == @locale}>{label}</option>
            </select>
          </form>
          <button :if={@can_self_update and @update in [nil, :up_to_date]} phx-click="check_update" class={btn_ghost()}>
            {gettext("Check for updates")}
          </button>
          <button :if={@update == :checking} disabled class={btn_ghost()}>{gettext("Checking...")}</button>
          <a
            :if={is_binary(@update)}
            href={"https://github.com/pepe-agent/pepe/releases/tag/v#{@update}"}
            target="_blank"
            rel="noopener"
            class={btn_ghost()}
          >
            {gettext("View changelog ↗")}
          </a>
          <button
            :if={is_binary(@update)}
            phx-click="do_update"
            data-confirm={gettext("Download and install v%{v} now? Restart Pepe afterward to run it.", v: @update)}
            class={btn()}
          >
            {gettext("Update to v%{v}", v: @update)}
          </button>
          <button phx-click="config_reload" class={btn_ghost()}>{gettext("Reload from disk")}</button>
        </.view_header>

        <div class="flex min-h-0 flex-1 flex-col gap-3 p-6">
          <form phx-submit="config_save" class="flex min-h-0 flex-1 flex-col gap-3">
            <textarea
              name="json"
              spellcheck="false"
              class="min-h-0 w-full flex-1 resize-none rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm leading-relaxed text-zinc-100 outline-none focus:border-orange-500 focus:ring-1 focus:ring-orange-500"
            >{@config_text}</textarea>
            <div class="flex items-center gap-3">
              <button type="submit" class={btn()}>{gettext("Save config")}</button>
              <span class="text-sm text-zinc-500">
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
  def handle_info({:update_result, {:newer, v}}, socket), do: {:noreply, assign(socket, update: v)}

  def handle_info({:update_result, :up_to_date}, socket),
    do: {:noreply, socket |> assign(update: :up_to_date) |> put_flash(:info, gettext("You're on the latest version."))}

  def handle_info({:update_result, :error}, socket),
    do: {:noreply, socket |> assign(update: nil) |> put_flash(:error, gettext("Couldn't check for updates."))}

  @impl true
  def handle_event("set_locale", %{"locale" => code}, socket) do
    if Config.known_locale?(code) do
      Config.set_locale(code)
      # Re-navigate so the LiveLocale on_mount re-applies the locale to a fresh process and the whole
      # page re-renders translated (this process already had the old locale set at mount time).
      {:noreply, push_navigate(socket, to: "/config?scope=#{socket.assigns.scope}")}
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown language."))}
    end
  end

  def handle_event("check_update", _p, socket) do
    parent = self()

    Task.start(fn -> send(parent, {:update_result, update_status()}) end)

    {:noreply, assign(socket, update: :checking)}
  end

  def handle_event("do_update", _p, socket) do
    flash =
      case Pepe.Update.run() do
        {:ok, :updated, v} -> {:info, gettext("Updated to v%{v}. Restart Pepe to run the new version.", v: v)}
        {:ok, :up_to_date, _} -> {:info, gettext("Already on the latest version.")}
        {:error, _} -> {:error, gettext("Update failed. Try `pepe update` from a terminal.")}
      end

    {:noreply, socket |> assign(update: nil) |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  def handle_event("config_save", %{"json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        # The operator edited the whole config as raw JSON; write it through the serialized path
        # so it doesn't race (and lose) a concurrent write from a running agent turn.
        Config.update(fn _ -> map end)
        Pepe.Gateways.Supervisor.reload_telegram()

        {:noreply,
         socket
         |> assign(config_text: pretty(map), projects: Config.project_slugs())
         |> put_flash(:info, gettext("Config saved."))}

      {:ok, _} ->
        {:noreply, put_flash(socket, :error, gettext("The top level must be a JSON object { ... }."))}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid JSON: %{msg}", msg: Exception.message(err)))}
    end
  end

  def handle_event("config_reload", _p, socket) do
    {:noreply, assign(socket, config_text: read_config())}
  end

  # Changing the project stays on this page; creating one jumps to its Agents.
  def handle_event("set_scope", %{"scope" => scope}, socket) do
    {:noreply, push_navigate(socket, to: "/config?scope=#{scope}")}
  end

  def handle_event("toggle_new_project", _p, socket) do
    {:noreply, assign(socket, new_project: !socket.assigns.new_project)}
  end

  def handle_event("project_add", %{"name" => name}, socket) do
    name = String.trim(name)

    case Config.add_project(name) do
      :ok -> {:noreply, push_navigate(socket, to: "/agents?scope=#{name}")}
      _ -> {:noreply, put_flash(socket, :error, gettext("Invalid or duplicate project name."))}
    end
  end

  defp update_status do
    case Pepe.Update.latest() do
      {:ok, v} -> if Pepe.Update.newer?(v), do: {:newer, v}, else: :up_to_date
      _ -> :error
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
