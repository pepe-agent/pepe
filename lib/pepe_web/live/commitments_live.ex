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
    # Every section below is scope-filtered, so the empty state has to be judged on the
    # scoped total too - gating it on the unfiltered list rendered a completely blank
    # page whenever a project was selected and had no commitments of its own.
    scoped = scoped_by_agent(assigns.commitments, assigns.scope, & &1.agent)

    assigns =
      assign(assigns,
        scoped_total: length(scoped),
        awaiting: by_state(scoped, "awaiting_confirmation"),
        scheduled: by_state(scoped, "scheduled"),
        firing: by_state(scoped, "firing"),
        delivered: by_state(scoped, "delivered"),
        due_options: due_options()
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="commitments" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🤝"
          title={gettext("Commitments")}
          desc={gettext("Follow-ups an agent notices in conversation: a user asking to be reminded, or the agent promising to check on something. Not created by hand; enable \"commitments\" on an agent to turn this on.")}
        />
        <div class="flex-1 space-y-6 overflow-y-auto p-4 sm:p-6">
          <div :if={@scoped_total == 0} class="text-[15px] text-zinc-500">
            {gettext("No commitments yet.")}
          </div>
          <p :if={@scoped_total > 0} class="text-sm leading-relaxed text-zinc-500">
            {gettext(
              "“%{reminder}” just sends you a message when it comes due. “%{promise}” re-runs the agent first, so it actually does the thing before it answers.",
              reminder: origin_type_label("user_reminder"),
              promise: origin_type_label("agent_promise")
            )}
          </p>
          <.commitment_section
            :if={@awaiting != []}
            title={gettext("Awaiting your ok")}
            commitments={@awaiting}
            due_options={@due_options}
          />
          <.commitment_section :if={@scheduled != []} title={gettext("Scheduled")} commitments={@scheduled} />
          <.commitment_section
            :if={@firing != []}
            title={gettext("Stuck")}
            desc={gettext("Interrupted mid-delivery. It will not retry on its own; cancel it.")}
            commitments={@firing}
          />
          <.commitment_section :if={@delivered != []} title={gettext("Delivered")} commitments={@delivered} />
        </div>
      </main>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :desc, :string, default: nil
  attr :commitments, :list, required: true
  attr :due_options, :list, default: []

  defp commitment_section(assigns) do
    ~H"""
    <div>
      <div class="mb-2">
        <div class="text-sm font-semibold uppercase tracking-wider text-zinc-500">{@title}</div>
        <div :if={@desc} class={hlp()}>{@desc}</div>
      </div>
      <div class="space-y-3">
        <div :for={c <- @commitments} class={card()}>
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div class="min-w-0">
              <span class="font-medium">{c.text}</span>
              <span class="ml-2 rounded bg-zinc-700 px-1.5 text-sm text-zinc-300" title={origin_type_hint(c.origin_type)}>
                {origin_type_label(c.origin_type)}
              </span>
              <span :if={c.pending_delivery} class="ml-1 rounded bg-amber-700 px-1.5 text-sm">{gettext("Fired · delivering")}</span>
            </div>
            <div :if={c.state != "awaiting_confirmation" or is_integer(c.due_at)} class="flex shrink-0 flex-wrap gap-1 text-sm">
              <button :if={c.state == "awaiting_confirmation"} phx-click="confirm" phx-value-id={c.id} class={btn_ghost()}>{gettext("Confirm")}</button>
              <button phx-click="cancel" phx-value-id={c.id} data-confirm={gettext("Cancel commitment %{name}?", name: c.text)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
            </div>
          </div>
          <div class="mt-1 text-sm text-zinc-400">
            {c.agent} · {gettext("due")} {c.due_when || gettext("unresolved")} · {watch_origin_label(c.origin)}
          </div>
          <div :if={c.source_excerpt} class="truncate text-sm text-zinc-500">“<em>{c.source_excerpt}</em>”</div>

          <form
            :if={c.state == "awaiting_confirmation" and not is_integer(c.due_at)}
            phx-submit="confirm_with_date"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input type="hidden" name="commitment_id" value={c.id} />
            <select name="due_when" class={[fld(), "sm:w-48"]}>
              <option value="" disabled selected={due_match(c.due_when) not in Enum.map(@due_options, &elem(&1, 1))}>
                {gettext("Pick when it's due")}
              </option>
              <option :for={{label, value} <- @due_options} value={value} selected={value == due_match(c.due_when)}>
                {label}
              </option>
            </select>
            <input
              type="text"
              name="due_custom"
              placeholder={gettext("or: in 5 days")}
              class={[fld(), "sm:w-40"]}
            />
            <button type="submit" class={btn_ghost()}>{gettext("Confirm with this date")}</button>
            <button type="button" phx-click="cancel" phx-value-id={c.id} data-confirm={gettext("Cancel commitment %{name}?", name: c.text)}
              class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
            <p class={[hlp(), "w-full"]}>
              {gettext("Pick a day from the list, or type an exact interval like “in 5 days” or “in 3 weeks”; what you type wins.")}
            </p>
          </form>
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

  # Same "still need a clear due time" gate the `commitment` tool's own confirm applies
  # (Pepe.Tools.Commitment.resolve_and_confirm/2) - this was the dashboard's own gap: an
  # awaiting-confirmation commitment whose due date never resolved used to have a plain
  # Confirm button here that quietly did nothing, with no way to supply the missing date
  # short of switching to chat and using the tool instead.
  def handle_event("confirm_with_date", %{"commitment_id" => id} = params, socket) do
    case Config.get_commitment(id) do
      %{} = c ->
        phrase = due_phrase(params)
        due_at = phrase != "" && Pepe.Commitments.DueDate.resolve(phrase, System.system_time(:second))

        socket =
          if is_integer(due_at) do
            Config.put_commitment(%{c | state: "scheduled", due_when: phrase, due_at: due_at})
            assign(socket, commitments: Config.commitments())
          else
            put_flash(
              socket,
              :error,
              gettext("Still need a clear due time. Pick a day from the list, or type an interval like “in 5 days”.")
            )
          end

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
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

  defp by_state(commitments, state), do: Enum.filter(commitments, &(&1.state == state))

  # What the operator typed wins over the picked option: the text box exists only for the
  # "in N days"/"in N weeks" arm of the grammar, which can't be enumerated in a list.
  defp due_phrase(params) do
    custom = params |> Map.get("due_custom", "") |> to_string() |> String.trim()
    if custom != "", do: custom, else: params |> Map.get("due_when", "") |> to_string() |> String.trim()
  end

  defp due_match(due_when), do: (due_when || "") |> String.downcase() |> String.trim()

  defp origin_type_label("agent_promise"), do: gettext("agent will do it")
  defp origin_type_label("user_reminder"), do: gettext("reminder for you")
  defp origin_type_label(other), do: to_string(other)

  defp origin_type_hint("agent_promise"),
    do: gettext("When it comes due, the original agent session is re-run so the agent does the thing before replying.")

  defp origin_type_hint("user_reminder"),
    do: gettext("When it comes due, you get a message on the channel this came from. The agent doesn't run again.")

  defp origin_type_hint(_other), do: nil

  # The whole accepted vocabulary of `Pepe.Commitments.DueDate.resolve/3`, offered as a
  # list instead of a text box: anything outside it resolves to nil, and there is nothing
  # on a free-text input that tells an operator where the edges are.
  @weekday_names ~w(monday tuesday wednesday thursday friday saturday sunday)

  defp due_options do
    today = today_in_default_tz()

    [{gettext("Today"), "today"}, {gettext("Tomorrow"), "tomorrow"}] ++
      weekday_options(today) ++
      [
        {gettext("In 2 days"), "in 2 days"},
        {gettext("In 3 days"), "in 3 days"},
        {gettext("In 1 week"), "in 1 week"},
        {gettext("In 2 weeks"), "in 2 weeks"}
      ]
  end

  # A bare weekday name that lands on *today* is deliberately ambiguous to `DueDate`
  # (today, or seven days out?) and resolves to nil - so for today's own weekday the list
  # offers the unambiguous "next <day>" form, which that module already understands.
  defp weekday_options(today) do
    dow = Date.day_of_week(today)

    @weekday_names
    |> Enum.with_index(1)
    |> Enum.map(fn
      {name, ^dow} -> {gettext("Next %{weekday}", weekday: weekday_label(name)), "next " <> name}
      {name, _n} -> {weekday_label(name), name}
    end)
  end

  defp today_in_default_tz do
    case DateTime.shift_zone(DateTime.utc_now(), Pepe.Config.default_timezone()) do
      {:ok, now} -> DateTime.to_date(now)
      _ -> Date.utc_today()
    end
  end

  defp weekday_label("monday"), do: gettext("Monday")
  defp weekday_label("tuesday"), do: gettext("Tuesday")
  defp weekday_label("wednesday"), do: gettext("Wednesday")
  defp weekday_label("thursday"), do: gettext("Thursday")
  defp weekday_label("friday"), do: gettext("Friday")
  defp weekday_label("saturday"), do: gettext("Saturday")
  defp weekday_label("sunday"), do: gettext("Sunday")
end
