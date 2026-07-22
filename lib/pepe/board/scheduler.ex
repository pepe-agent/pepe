defmodule Pepe.Board.Scheduler do
  @moduledoc """
  The in-app board timer. Ticks on a short interval and, for every board: promotes a `todo`
  card to `ready` once its dependencies are `done`, blocks a `running` card whose claim has
  outlived the board's `claim_timeout_s`, and (only for a board with `auto_dispatch: true`)
  claims and dispatches its `ready` cards to their assigned agent.

  There is no separate coordinator process gating card mutations. This scheduler and
  `Pepe.Tools.Board` (and the dashboard) all call straight into `Pepe.Board`'s functions,
  which themselves serialize the actual read-check-write as one atomic conditional
  `UPDATE` (or transaction, for the few that need to read other cards) against
  `Pepe.Repo`; see `Pepe.Board`'s moduledoc. Funnelling this scheduler's own tick
  through one more GenServer.call would only make the slow part (a card mutation)
  block every other board's tick while one claim is mid-write.

  Like `Pepe.Cron.Scheduler`, a dispatch's claim is released only by its task's `:DOWN`:
  a message that arrives however the run ends (a normal finish that never called
  `complete`/`block`, or a crash) is the only kind of release worth having; anything else
  leaves a card claimed forever the moment its run doesn't reach a tidy end.
  """

  use GenServer
  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config

  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Pepe.Config.Journal.put_source("board")
    schedule_tick()
    {:ok, %{running: %{}, refs: %{}}}
  end

  @doc "Card ids with a dispatched run in flight right now (used by the dashboard and by tests)."
  def running, do: GenServer.call(__MODULE__, :running)

  @impl true
  def handle_call(:running, _from, state), do: {:reply, Map.keys(state.running), state}

  @impl true
  def handle_info(:tick, state) do
    state = Enum.reduce(Config.boards(), state, &tick_board/2)
    schedule_tick()
    {:noreply, state}
  end

  # The dispatch ended, however it ended: crash, or a normal finish that simply never
  # called `complete`/`block`. Either way, re-check the card: if still `running`, that is a
  # protocol violation (see the moduledoc) and it gets blocked, never silently re-dispatched.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{card_id, claimed_by, claimed_at}, refs} ->
        Pepe.Board.block_if_still_running(card_id, claimed_by, claimed_at)
        {:noreply, %{state | refs: refs, running: Map.delete(state.running, card_id)}}
    end
  end

  defp tick_board(board, state) do
    cards = Config.board_cards_for(board.id)

    Enum.each(cards, fn card -> if card.status == "todo", do: Pepe.Board.promote_if_ready(card.id) end)
    Enum.each(cards, fn card -> if card.status == "running", do: Pepe.Board.reclaim_if_timed_out(card.id, board.claim_timeout_s) end)

    maybe_dispatch(board, state)
  end

  # Every board is checked, not just ones with auto_dispatch: true: a card can override
  # its board's own setting either way (see Pepe.Board.effective_auto_dispatch?/2), so an
  # otherwise-manual board can still have one card that fires on its own, and vice versa.
  defp maybe_dispatch(board, state) do
    board.id
    |> Pepe.Board.due_for_dispatch()
    |> Enum.filter(&Pepe.Board.effective_auto_dispatch?(board, &1))
    |> Enum.reduce(state, &dispatch_card/2)
  end

  # Already tracked as in flight this tick (e.g. `due_for_dispatch/1` listed it twice across
  # boards, which can't happen, but a card claimed a moment ago via the tool/dashboard
  # between the query and here can): `claim/2`'s own CAS is what actually prevents a double
  # dispatch; this is just a cheap skip for the case it already lost that race.
  defp dispatch_card(card, state) do
    if Map.has_key?(state.running, card.id) do
      state
    else
      case Pepe.Board.claim(card.id, card.assignee) do
        {:ok, claimed} -> start(claimed, state)
        {:error, _} -> state
      end
    end
  end

  # Supervised (not a bare Task.start), same reason as `Pepe.Cron.Scheduler`: so a graceful
  # shutdown can see and drain in-flight card runs instead of the VM just killing them.
  # Monitored so the claim is released by the run ending, whatever ending it gets.
  defp start(card, state) do
    key = session_key(card)

    case Task.Supervisor.start_child(Pepe.Board.TaskSupervisor, fn -> dispatch(card, key) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        claim = {card.id, card.claimed_by, card.claimed_at}
        %{state | running: Map.put(state.running, card.id, ref), refs: Map.put(state.refs, ref, claim)}

      _ ->
        Logger.warning("board card #{card.id}: could not start the run")
        state
    end
  end

  # `ephemeral: true` deliberately: a card session never enters `persist_sessions`/
  # restore-on-boot. If the app restarts mid-card, the session is just gone; the board's
  # own `claim_timeout_s` (and, on a real crash, `:DOWN` above) are the recovery path, not
  # session resume.
  defp dispatch(card, key) do
    SessionSupervisor.ensure(key, card.assignee, ephemeral: true)
    Session.chat(key, prompt(card), [])
  end

  defp session_key(card), do: "board:#{card.board}:#{card.id}"

  @prompt_note """
  This is a fresh session with no memory of any other chat: the card below is everything you \
  need. You do NOT need to pass a card id to a `board` tool call you make from this session \
  (claim/complete/block/comment); it is inferred automatically from this session. Call \
  `board complete` when you're done, or `board block` with a reason if you can't finish it, \
  before you stop: a reply with no matching tool call leaves the card stuck.
  """

  defp prompt(card) do
    """
    #{@prompt_note}

    Card: #{card.title}

    #{card.body}
    """
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
