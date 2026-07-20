defmodule PepeWeb.BoardLive do
  @moduledoc """
  Board section: durable task/work-item cards, grouped by status. Mechanics only: the
  agent-facing actions (claim/complete/block/comment/link) live in `Pepe.Tools.Board`; this
  page is the human side: create a board or card, claim one, unblock or archive one. See
  `Pepe.Board` for the full state machine.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Board
  alias Pepe.Config

  @statuses ~w(todo ready running blocked done)

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pepe.PubSub, Board.events_topic())

    {:ok,
     assign(socket,
       page_title: "Pepe · Board",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       boards: scoped_boards(params["scope"] || "all"),
       selected: nil,
       cards: [],
       show_archived: false,
       creating_board: false,
       creating_card: false,
       board_form: board_form(%{}),
       card_form: card_form(%{}),
       statuses: @statuses
     )}
  end

  # A card changed somewhere else (the tool, the scheduler): refresh if we're looking at
  # its board, or just the board list's counts otherwise. No per-event diffing: a full
  # re-fetch of one board's (small) card list is cheap and never drifts.
  @impl true
  def handle_info({:board_event, _card_id, _event}, socket) do
    {:noreply,
     assign(socket,
       boards: scoped_boards(socket.assigns.scope),
       cards: (socket.assigns.selected && Config.board_cards_for(socket.assigns.selected)) || []
     )}
  end

  defp scoped_boards(scope), do: Config.boards() |> Enum.filter(&in_scope?(&1.id, scope))

  defp board_changeset(attrs) do
    types = %{name: :string, project: :string, auto_dispatch: :boolean, claim_timeout_s: :integer}

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:name])
  end

  defp board_form(attrs), do: to_form(board_changeset(attrs), as: :board)

  defp card_changeset(attrs) do
    types = %{title: :string, body: :string, assignee: :string, priority: :integer}

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types))
    |> Changeset.validate_required([:title])
  end

  defp card_form(attrs), do: to_form(card_changeset(attrs), as: :card)

  defp column(cards, status), do: Enum.filter(cards, &(&1.status == status))

  defp parse_tri_state("true"), do: true
  defp parse_tri_state("false"), do: false
  defp parse_tri_state(_), do: nil

  defp parse_tri_state_select("on"), do: true
  defp parse_tri_state_select("off"), do: false
  defp parse_tri_state_select(_), do: nil

  defp column_label("todo"), do: gettext("To do")
  defp column_label("ready"), do: gettext("Ready")
  defp column_label("running"), do: gettext("Running")
  defp column_label("blocked"), do: gettext("Blocked")
  defp column_label("done"), do: gettext("Done")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="board" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🗂️"
          title={gettext("Board")}
          desc={gettext("Durable task cards with dependencies, claimed and worked by agents (or you): a resumable queue, not a chat.")}
        >
          <button :if={@selected && !@creating_card} phx-click="card_new" class={btn()}>{gettext("+ New card")}</button>
          <button :if={@creating_card} phx-click="card_cancel" class={btn_ghost()}>&larr; {gettext("Back")}</button>
          <button :if={@selected && !@creating_card} phx-click="board_back" class={btn_ghost()}>&larr; {gettext("All boards")}</button>
          <button :if={!@selected and !@creating_board} phx-click="board_new" class={btn()}>{gettext("+ New board")}</button>
          <button :if={@creating_board} phx-click="board_cancel" class={btn_ghost()}>&larr; {gettext("Back")}</button>
        </.view_header>

        <div :if={@creating_board} class="min-h-0 flex-1 overflow-y-auto p-6">
          <div class="max-w-lg">
            <.form id="board-form" for={@board_form} phx-submit="board_create" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("+ New board")}</div>
              <.input field={@board_form[:name]} label={gettext("Name")} placeholder={gettext("Engineering")} />
              <div>
                <label class={lbl()}>{gettext("Project")}</label>
                <select name="board[project]" class={fld()}>
                  <option value="" selected={@scope in ["all", "root"]}>{gettext("Principal")}</option>
                  <option :for={p <- @projects} value={p} selected={@scope == p}>{p}</option>
                </select>
              </div>
              <label class="flex items-start gap-2.5 text-sm">
                <input type="checkbox" name="board[auto_dispatch]" value="true" class="mt-0.5" />
                <span>
                  {gettext("Auto-dispatch")}
                  <p class={hlp()}>{gettext("A ready card with an assignee fires on its own. Off (the default): only an explicit claim starts one. Do that from here, or have the assignee call the board tool.")}</p>
                </span>
              </label>
              <div>
                <label class={lbl()}>{gettext("Claim timeout (seconds)")}</label>
                <input type="number" min="0" name="board[claim_timeout_s]" value="1800" class={fld()} />
                <p class={hlp()}>{gettext("A running claim older than this is treated as stalled and blocked. 0 = never.")}</p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Create board")}</button>
                <button type="button" phx-click="board_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>
        </div>

        <div :if={@creating_card} class="min-h-0 flex-1 overflow-y-auto p-6">
          <div class="max-w-lg">
            <.form id="card-form" for={@card_form} phx-submit="card_create" class="space-y-4">
              <div class="text-lg font-semibold">{gettext("+ New card")}</div>
              <.input field={@card_form[:title]} label={gettext("Title")} placeholder={gettext("Fix the checkout timeout")} />
              <.input field={@card_form[:body]} type="textarea" rows="3" label={gettext("What needs doing")}
                placeholder={gettext("Everything the assignee needs to know: this is all it gets, no chat memory.")} />
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class={lbl()}>{gettext("Assignee")}</label>
                  <select name="card[assignee]" class={fld()}>
                    <option value="">{gettext("(unassigned)")}</option>
                    <option :for={a <- scoped_agent_names(@scope)} value={a}>{a}</option>
                  </select>
                </div>
                <.input field={@card_form[:priority]} type="number" label={gettext("Priority")} value="0" />
              </div>
              <div>
                <label class={lbl()}>{gettext("Auto-dispatch")} <span class="text-zinc-600">{gettext("(overrides the board's own setting)")}</span></label>
                <select name="card[auto_dispatch]" class={fld()}>
                  <option value="">{gettext("Inherit from the board")}</option>
                  <option value="true">{gettext("On for this card")}</option>
                  <option value="false">{gettext("Off for this card")}</option>
                </select>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Create card")}</button>
                <button type="button" phx-click="card_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>
        </div>

        <div :if={!@selected and !@creating_board and !@creating_card} class="flex-1 space-y-4 overflow-y-auto p-6">
          <div :for={b <- @boards} class={[card(), "cursor-pointer"]} phx-click="board_select" phx-value-id={b.id}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{b.name}</span>
                <span class="ml-2 text-sm text-zinc-500">{b.id}</span>
                <span :if={b.auto_dispatch} class="ml-2 rounded bg-orange-700/40 px-1.5 text-sm text-orange-300">{gettext("auto-dispatch")}</span>
              </div>
              <button phx-click="board_remove" phx-value-id={b.id} data-confirm={gettext("Remove board %{name}? Cards on it must be deleted first.", name: b.name)}
                class={[btn_ghost(), "shrink-0 text-red-400 hover:text-red-300"]}>✕</button>
            </div>
            <div class="mt-1 text-sm text-zinc-500">{length(Config.board_cards_for(b.id))} {gettext("card(s)")}</div>
          </div>
          <p :if={@boards == []} class="text-[15px] text-zinc-500">{gettext("No boards yet. Create one with “+ New board”.")}</p>
        </div>

        <div :if={@selected && !@creating_card} class="flex-1 overflow-x-auto overflow-y-auto p-6">
          <div class="mb-4 flex items-center gap-3">
            <span class="text-lg font-semibold">{Enum.find(@boards, &(&1.id == @selected)) |> then(& &1 && &1.name)}</span>
            <label class="flex items-center gap-1.5 text-sm text-zinc-400">
              <input type="checkbox" checked={@show_archived} phx-click="toggle_archived" class="accent-orange-500" /> {gettext("Show archived")}
            </label>
          </div>
          <div class="flex gap-4">
            <div :for={status <- @statuses} class="w-72 shrink-0">
              <div class="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wider text-zinc-400">
                {column_label(status)} <span class="text-zinc-600">{length(column(@cards, status))}</span>
              </div>
              <div class="space-y-3">
                <div :for={c <- column(@cards, status)} class={card()}>
                  <div class="font-medium">{c.title}</div>
                  <div class="mt-0.5 text-sm text-zinc-500">{c.id}</div>
                  <div :if={c.assignee} class="mt-1 text-sm text-zinc-400">{gettext("assignee")}: {c.assignee}</div>
                  <div :if={c.priority != 0} class="text-sm text-zinc-500">{gettext("priority")}: {c.priority}</div>
                  <div :if={c.depends_on != []} class="text-sm text-zinc-500">{gettext("depends on")}: {Enum.join(c.depends_on, ", ")}</div>
                  <div :if={c.status == "running" and c.claimed_by} class="text-sm text-zinc-500">{gettext("claimed by")}: {c.claimed_by}</div>
                  <div :if={c.block_reason} class="mt-1 text-sm text-amber-400">⚠ {c.block_reason}</div>
                  <div class="mt-2 flex items-center gap-1.5 text-sm text-zinc-500">
                    {gettext("auto-dispatch")}:
                    <select phx-change="card_set_auto_dispatch" phx-value-id={c.id} name="value"
                      class="rounded-lg border border-zinc-800 bg-zinc-900 px-2 py-1 text-sm text-zinc-300 outline-none transition hover:border-zinc-700 focus:border-orange-500 focus:ring-1 focus:ring-orange-500">
                      <option value="inherit" selected={is_nil(c.auto_dispatch)}>{gettext("inherit")}</option>
                      <option value="on" selected={c.auto_dispatch == true}>{gettext("on")}</option>
                      <option value="off" selected={c.auto_dispatch == false}>{gettext("off")}</option>
                    </select>
                  </div>
                  <div class="mt-2 flex gap-1.5 text-sm">
                    <button :if={c.status == "ready"} phx-click="card_claim" phx-value-id={c.id} class={btn_ghost()}>{gettext("Claim")}</button>
                    <button :if={c.status == "blocked"} phx-click="card_unblock" phx-value-id={c.id} class={btn_ghost()}>{gettext("Unblock")}</button>
                    <button :if={c.status in ["running", "blocked", "done"]} phx-click="card_archive" phx-value-id={c.id}
                      data-confirm={c.status == "running" && gettext("This card is still running. Archive it anyway?")}
                      class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>{gettext("Archive")}</button>
                  </div>
                </div>
              </div>
            </div>
            <div :if={@show_archived} class="w-72 shrink-0">
              <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-400">
                {gettext("Archived")} <span class="text-zinc-600">{length(column(@cards, "archived"))}</span>
              </div>
              <div class="space-y-3">
                <div :for={c <- column(@cards, "archived")} class={[card(), "opacity-60"]}>
                  <div class="font-medium">{c.title}</div>
                  <div class="mt-0.5 text-sm text-zinc-500">{c.id}</div>
                  <button phx-click="card_unarchive" phx-value-id={c.id} class={[btn_ghost(), "mt-2"]}>{gettext("Unarchive")}</button>
                </div>
              </div>
            </div>
          </div>
          <p :if={@cards == []} class="mt-4 text-[15px] text-zinc-500">{gettext("No cards yet. Create one with “+ New card”.")}</p>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("board_new", _p, socket),
    do: {:noreply, assign(socket, creating_board: true, board_form: board_form(%{}))}

  def handle_event("board_cancel", _p, socket), do: {:noreply, assign(socket, creating_board: false)}

  def handle_event("board_create", %{"board" => p}, socket) do
    cs = %{board_changeset(p) | action: :validate}

    if cs.valid? do
      attrs = %{
        name: Changeset.get_field(cs, :name),
        project: blank(p["project"]),
        auto_dispatch: p["auto_dispatch"] == "true",
        claim_timeout_s: parse_iterations(p["claim_timeout_s"])
      }

      case Board.create_board(attrs) do
        {:ok, board} ->
          {:noreply,
           socket
           |> assign(
             boards: scoped_boards(socket.assigns.scope),
             creating_board: false,
             selected: board.id,
             cards: Config.board_cards_for(board.id)
           )
           |> put_flash(:info, gettext("Board created."))}

        {:error, :already_exists} ->
          {:noreply, put_flash(socket, :error, gettext("A board with that name already exists there."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create the board."))}
      end
    else
      {:noreply, assign(socket, board_form: to_form(cs, as: :board))}
    end
  end

  def handle_event("board_select", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: id, cards: Config.board_cards_for(id), show_archived: false)}

  def handle_event("board_back", _p, socket), do: {:noreply, assign(socket, selected: nil, cards: [])}

  def handle_event("board_remove", %{"id" => id}, socket) do
    case Board.delete_board(id) do
      :ok ->
        {:noreply, assign(socket, boards: scoped_boards(socket.assigns.scope))}

      {:error, {:not_empty, n}} ->
        {:noreply, put_flash(socket, :error, gettext("This board has %{n} card(s). Delete them first.", n: n))}
    end
  end

  def handle_event("toggle_archived", _p, socket), do: {:noreply, assign(socket, show_archived: !socket.assigns.show_archived)}

  def handle_event("card_new", _p, socket), do: {:noreply, assign(socket, creating_card: true, card_form: card_form(%{}))}
  def handle_event("card_cancel", _p, socket), do: {:noreply, assign(socket, creating_card: false)}

  def handle_event("card_create", %{"card" => p}, socket) do
    cs = %{card_changeset(p) | action: :validate}

    if cs.valid? do
      attrs = %{
        board: socket.assigns.selected,
        title: Changeset.get_field(cs, :title),
        body: Changeset.get_field(cs, :body),
        assignee: blank(p["assignee"]),
        priority: parse_iterations(p["priority"]) || 0,
        auto_dispatch: parse_tri_state(p["auto_dispatch"])
      }

      case Board.create_card(attrs) do
        {:ok, _card} ->
          {:noreply,
           socket
           |> assign(creating_card: false, cards: Config.board_cards_for(socket.assigns.selected))
           |> put_flash(:info, gettext("Card created."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create the card."))}
      end
    else
      {:noreply, assign(socket, card_form: to_form(cs, as: :card))}
    end
  end

  def handle_event("card_claim", %{"id" => id}, socket) do
    Board.claim(id, "dashboard")
    {:noreply, assign(socket, cards: Config.board_cards_for(socket.assigns.selected))}
  end

  def handle_event("card_set_auto_dispatch", %{"id" => id, "value" => value}, socket) do
    Board.set_auto_dispatch(id, parse_tri_state_select(value))
    {:noreply, assign(socket, cards: Config.board_cards_for(socket.assigns.selected))}
  end

  def handle_event("card_unblock", %{"id" => id}, socket) do
    Board.unblock(id)
    {:noreply, assign(socket, cards: Config.board_cards_for(socket.assigns.selected))}
  end

  def handle_event("card_archive", %{"id" => id}, socket) do
    Board.archive(id, force: true)
    {:noreply, assign(socket, cards: Config.board_cards_for(socket.assigns.selected))}
  end

  def handle_event("card_unarchive", %{"id" => id}, socket) do
    Board.unarchive(id)
    {:noreply, assign(socket, cards: Config.board_cards_for(socket.assigns.selected))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/board")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}
end
