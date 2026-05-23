defmodule PepeWeb.WatchesLive do
  @moduledoc "Watches section: one-shot \"notify me when X\" commitments."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Watches",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       watches: Config.watches()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="watches" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔭"
          title={gettext("Watches")}
          desc={gettext("One-shot “notify me when X happens”. A watch checks a condition on a timer, messages you once when it's met, then stops. Create them from chat.")}
        />
        <div class="flex-1 space-y-3 overflow-y-auto p-6">
          <div :if={@watches == []} class="text-[15px] text-zinc-500">
            {gettext("No watches. Ask an agent to \"notify me when ...\" from chat.")}
          </div>
          <div :for={w <- scoped_by_agent(@watches, @scope, & &1.agent)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{w.description}</span>
                <span class="ml-2 rounded bg-zinc-700 px-1.5 text-sm text-zinc-300">{w.state}</span>
                <span :if={w.pending_delivery} class="ml-1 rounded bg-amber-700 px-1.5 text-sm">{gettext("Fired · delivering")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <button :if={w.state == "pending"} phx-click="watch_pause" phx-value-id={w.id} class={btn_ghost()}>{gettext("Pause")}</button>
                <button :if={w.state == "paused"} phx-click="watch_resume" phx-value-id={w.id} class={btn_ghost()}>{gettext("Resume")}</button>
                <button phx-click="watch_cancel" phx-value-id={w.id} data-confirm={gettext("Cancel watch %{name}?", name: w.description)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">
              {w.trigger["type"]} · {gettext("every")} {w.interval_s}s · {gettext("checks")} {w.checks}/{w.max_checks} · {watch_origin_label(w.origin)}
            </div>
            <div class="truncate text-sm text-zinc-500"><code>{w.trigger["command"] || w.trigger["prompt"]}</code></div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("watch_pause", %{"id" => id}, socket),
    do: {:noreply, watch_set(socket, id, %{state: "paused"})}

  def handle_event("watch_resume", %{"id" => id}, socket),
    do: {:noreply, watch_set(socket, id, %{state: "pending", next_check: nil})}

  def handle_event("watch_cancel", %{"id" => id}, socket) do
    Config.delete_watch(id)
    {:noreply, assign(socket, watches: Config.watches())}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/watches")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp watch_set(socket, id, changes) do
    case Config.get_watch(id) do
      nil ->
        socket

      w ->
        Config.put_watch(struct(w, changes))
        assign(socket, watches: Config.watches())
    end
  end
end
