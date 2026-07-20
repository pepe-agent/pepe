defmodule PepeWeb.CommitmentsLive do
  @moduledoc "Commitments section: follow-ups noticed automatically from conversation."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Commitments",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       commitments: Config.commitments()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="commitments" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🤝"
          title={gettext("Commitments")}
          desc={gettext("Follow-ups noticed automatically from conversation - a user asking to be reminded, or an agent promising to check on something. Not created by hand; toggle \"commitments\" on an agent to turn this on.")}
        />
        <div class="flex-1 space-y-6 overflow-y-auto p-6">
          <div :if={@commitments == []} class="text-[15px] text-zinc-500">
            {gettext("No commitments yet.")}
          </div>
          <.commitment_section
            :if={awaiting(@commitments, @scope) != []}
            title={gettext("Awaiting your ok")}
            commitments={awaiting(@commitments, @scope)}
          />
          <.commitment_section
            :if={scheduled(@commitments, @scope) != []}
            title={gettext("Scheduled")}
            commitments={scheduled(@commitments, @scope)}
          />
          <.commitment_section
            :if={delivered(@commitments, @scope) != []}
            title={gettext("Delivered")}
            commitments={delivered(@commitments, @scope)}
          />
        </div>
      </main>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :commitments, :list, required: true

  defp commitment_section(assigns) do
    ~H"""
    <div>
      <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{@title}</div>
      <div class="space-y-3">
        <div :for={c <- @commitments} class={card()}>
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0">
              <span class="font-medium">{c.text}</span>
              <span class="ml-2 rounded bg-zinc-700 px-1.5 text-sm text-zinc-300">{c.origin_type}</span>
              <span :if={c.pending_delivery} class="ml-1 rounded bg-amber-700 px-1.5 text-sm">{gettext("Fired · delivering")}</span>
            </div>
            <div class="flex shrink-0 gap-1 text-sm">
              <button :if={c.state == "awaiting_confirmation"} phx-click="confirm" phx-value-id={c.id} class={btn_ghost()}>{gettext("Confirm")}</button>
              <button phx-click="cancel" phx-value-id={c.id} data-confirm={gettext("Cancel commitment %{name}?", name: c.text)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
            </div>
          </div>
          <div class="mt-1 text-sm text-zinc-400">
            {c.agent} · {gettext("due")} {c.due_when || gettext("unresolved")} · {watch_origin_label(c.origin)}
          </div>
          <div :if={c.source_excerpt} class="truncate text-sm text-zinc-500">"<em>{c.source_excerpt}</em>"</div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("confirm", %{"id" => id}, socket) do
    case Config.get_commitment(id) do
      %{due_at: due_at} = c when is_integer(due_at) ->
        Config.put_commitment(%{c | state: "scheduled"})

      _ ->
        :ok
    end

    {:noreply, assign(socket, commitments: Config.commitments())}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    Config.delete_commitment(id)
    {:noreply, assign(socket, commitments: Config.commitments())}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/commitments")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp awaiting(commitments, scope), do: filter(commitments, scope, "awaiting_confirmation")
  defp scheduled(commitments, scope), do: filter(commitments, scope, "scheduled")
  defp delivered(commitments, scope), do: filter(commitments, scope, "delivered")

  defp filter(commitments, scope, state) do
    commitments |> scoped_by_agent(scope, & &1.agent) |> Enum.filter(&(&1.state == state))
  end
end
