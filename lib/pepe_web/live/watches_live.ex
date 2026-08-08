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
    # The empty state has to follow the list that is actually rendered, not the unscoped one.
    assigns = assign(assigns, :visible, scoped_by_agent(assigns.watches, assigns.scope, & &1.agent))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="watches" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔭"
          title={gettext("Watches")}
          desc={gettext("One-shot “notify me when X happens”. A watch checks a condition on a timer, messages you once when it's met, then stops. Create them from chat.")}
        />
        <div class="flex-1 space-y-3 overflow-y-auto p-4 sm:p-6">
          <div :if={@visible == []} class="text-[15px] text-zinc-500">
            {gettext("No watches. Ask an agent to \"notify me when ...\" from chat.")}
          </div>
          <div :for={w <- @visible} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0">
                <span class="font-medium">{w.description}</span>
                <span class="ml-2 rounded bg-zinc-700 px-1.5 text-sm text-zinc-300">{state_label(w.state)}</span>
                <span :if={w.pending_delivery} class="ml-1 rounded bg-amber-700 px-1.5 text-sm">{gettext("Fired · delivering")}</span>
                <span :if={state_hint(w.state)} class="ml-2 text-sm text-zinc-500">{state_hint(w.state)}</span>
              </div>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                <button :if={w.state == "pending"} phx-click="watch_pause" phx-value-id={w.id} class={btn_ghost()}>{gettext("Pause")}</button>
                <button :if={w.state == "paused"} phx-click="watch_resume" phx-value-id={w.id} class={btn_ghost()}>{gettext("Resume")}</button>
                <button phx-click="watch_cancel" phx-value-id={w.id} data-confirm={gettext("Cancel watch %{name}?", name: w.description)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">
              {trigger_label(w.trigger)} · {interval_label(w.interval_s)} · {checks_label(w.checks, w.max_checks)} · {origin_label(w.origin)}
            </div>
            <div class="truncate text-sm text-zinc-500"><code>{w.trigger["command"] || w.trigger["prompt"]}</code></div>
            <div :if={next_check_label(w)} class="text-sm text-zinc-500">{next_check_label(w)}</div>
            <div :if={w.last_error} class="truncate text-sm text-red-400" title={w.last_error}>
              {gettext("Last check failed: %{error}", error: w.last_error)}
            </div>
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

  # The stored state is a developer-facing enum (see Pepe.Config.Watch); the screen isn't.
  defp state_label("pending"), do: gettext("Waiting")
  defp state_label("paused"), do: gettext("Paused")
  defp state_label("done"), do: gettext("Done")
  defp state_label("expired"), do: gettext("Expired")
  defp state_label("cancelled"), do: gettext("Cancelled")
  defp state_label(other), do: to_string(other)

  # Terminal states have no buttons left, so say why nothing can happen to them anymore.
  defp state_hint("done"), do: gettext("This watch already fired and stopped.")
  defp state_hint("expired"), do: gettext("Ran out of checks and stopped without firing.")
  defp state_hint("cancelled"), do: gettext("Cancelled. It won't run again.")
  defp state_hint(_state), do: nil

  defp trigger_label(%{"type" => "probe"}), do: gettext("shell check")
  defp trigger_label(%{"type" => "agent"}), do: gettext("asks the agent")
  defp trigger_label(_trigger), do: gettext("unknown check")

  defp interval_label(s) when is_integer(s) and s >= 3600 and rem(s, 3600) == 0,
    do: ngettext("every %{count} hour", "every %{count} hours", div(s, 3600))

  defp interval_label(s) when is_integer(s) and s >= 60 and rem(s, 60) == 0,
    do: ngettext("every %{count} minute", "every %{count} minutes", div(s, 60))

  defp interval_label(s) when is_integer(s) and s > 0,
    do: ngettext("every %{count} second", "every %{count} seconds", s)

  defp interval_label(_s), do: gettext("no interval set")

  # A watch expires once the counter hits the max, so the ratio needs to say so.
  defp checks_label(checks, max) when is_integer(max),
    do: gettext("check %{n} of %{max}, then it stops", n: checks || 0, max: max)

  defp checks_label(checks, _max), do: gettext("%{n} checks so far", n: checks || 0)

  defp origin_label(origin), do: gettext("notifies on %{channel}", channel: watch_origin_label(origin))

  defp next_check_label(%{state: "pending", next_check: ts}) when is_integer(ts),
    do: gettext("Next check %{at}", at: local_datetime(ts))

  defp next_check_label(%{state: "pending"}), do: gettext("Next check on the next tick")
  defp next_check_label(_watch), do: nil

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
