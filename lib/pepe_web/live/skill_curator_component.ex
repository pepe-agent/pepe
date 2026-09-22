defmodule PepeWeb.SkillCuratorComponent do
  @moduledoc """
  The skill curator on the Learning page: whether it is on, what it last did and when it runs
  next, buttons to run it now (or only preview what it would do), pause it, change how long a
  skill may sit unused, and the three lists a person needs to stay in control: the skills
  closest to going stale (each pinnable), what was archived (each restorable), and the recent
  changes to skills (each undoable).

  Self-contained like `PepeWeb.ConnectionsComponent`: it owns its events (addressed with
  `phx-target`), talks to `Pepe.Skills.Curator` directly and reports outcomes to the parent
  with `send(self(), {:flash, kind, message})`. A run happens in an async task, since one
  that includes the model pass can take a while.
  """
  use PepeWeb, :live_component
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI

  alias Pepe.Skills.Curator
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Curator.Status
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage

  @actor "user:dashboard"
  @undoable ~w(create edit patch write_file remove_file archive)

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:running, fn -> nil end)
     |> assign_new(:result, fn -> nil end)
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      status: Status.get(),
      archived: Lifecycle.archived(),
      changes: 40 |> Ledger.recent() |> Enum.filter(&(&1.action in @undoable)) |> Enum.take(8)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="skill-curator" class="rounded-xl border border-zinc-800 bg-zinc-900/40 p-4 sm:p-5">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2.5">
          <span class="text-[15px] font-semibold">{gettext("Skill curator")}</span>
          <span class={["rounded px-1.5 text-sm", pill_cls(@status)]}>{headline(@status)}</span>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button phx-click="run" phx-target={@myself} disabled={@running != nil} class={btn_ghost()}>
            {if @running == :run, do: gettext("Running..."), else: gettext("Run now")}
          </button>
          <button phx-click="preview" phx-target={@myself} disabled={@running != nil} class={btn_ghost()}>
            {if @running == :preview, do: gettext("Checking..."), else: gettext("Preview")}
          </button>
          <button :if={@status.paused} phx-click="resume" phx-target={@myself} class={btn_ghost()}>{gettext("Resume")}</button>
          <button :if={!@status.paused} phx-click="pause" phx-target={@myself} class={btn_ghost()}>{gettext("Pause")}</button>
        </div>
      </div>

      <p class="mt-2 text-sm leading-relaxed text-zinc-500">
        {gettext("Skills an agent wrote on its own are tidied automatically: after a while unused they are marked stale, then archived. Nothing is deleted, and you can restore any of them. Your own skills, installed ones and pinned ones are never touched.")}
      </p>

      <dl class="mt-3 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
        <div class="flex gap-2">
          <dt class="text-zinc-500">{gettext("Last run")}</dt>
          <dd class="min-w-0 text-zinc-300">{last_run(@status)}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="text-zinc-500">{gettext("Next run")}</dt>
          <dd class="text-zinc-300">{next_run(@status)}</dd>
        </div>
        <div class="flex gap-2">
          <dt class="text-zinc-500">{gettext("In its care")}</dt>
          <dd class="text-zinc-300">
            {gettext("%{active} active, %{stale} stale, %{archived} archived", active: @status.active, stale: @status.stale, archived: @status.archived)}
          </dd>
        </div>
      </dl>

      <div :if={@result} class="mt-3 rounded-lg border border-zinc-800 bg-zinc-950 p-3">
        <div class="mb-1 flex items-center justify-between text-sm text-zinc-400">
          <span>{@result.title}</span>
          <button phx-click="dismiss" phx-target={@myself} class="text-zinc-500 hover:text-zinc-300">{gettext("Dismiss")}</button>
        </div>
        <pre class="max-h-64 overflow-auto whitespace-pre-wrap font-mono text-sm leading-relaxed text-zinc-300">{@result.text}</pre>
      </div>

      <details class="mt-3">
        <summary class="cursor-pointer text-sm text-zinc-400 hover:text-zinc-200">{gettext("Settings")}</summary>
        <form phx-submit="save_settings" phx-target={@myself} class="mt-3 space-y-3">
          <div class="flex flex-wrap gap-x-6 gap-y-2">
            <label class="flex items-center gap-2 text-sm text-zinc-300">
              <input type="checkbox" name="enabled" value="true" checked={@status.settings["enabled"]} class={checkbox_cls()} />
              {gettext("Run automatically")}
            </label>
            <label class="flex items-center gap-2 text-sm text-zinc-300">
              <input type="checkbox" name="consolidate" value="true" checked={@status.settings["consolidate"]} class={checkbox_cls()} />
              {gettext("Also merge overlapping skills (uses a model run)")}
            </label>
          </div>
          <div class="grid gap-3 sm:grid-cols-4">
            <div :for={{key, label} <- number_fields()}>
              <label for={"curator-#{key}"} class={lbl()}>{label}</label>
              <input id={"curator-#{key}"} type="number" min="0" name={key} value={@status.settings[key]} class={fld_sm()} />
            </div>
          </div>
          <button type="submit" class={btn_ghost()}>{gettext("Save settings")}</button>
        </form>
      </details>

      <div :if={@status.most_idle != []} class="mt-4">
        <div class="mb-1 text-sm font-medium text-zinc-300">{gettext("Closest to going stale")}</div>
        <div :for={row <- @status.most_idle} class="flex items-center justify-between gap-3 rounded-lg px-2 py-1 text-sm hover:bg-zinc-900">
          <div class="min-w-0 truncate">
            <span class="font-medium text-zinc-200">{row.name}</span>
            <span class="ml-2 text-zinc-500">{gettext("idle %{days} days, used %{count} times", days: row.idle_days, count: row.use_count)}</span>
            <span :if={row.state == "stale"} class="ml-2 rounded bg-amber-800/40 px-1.5 text-amber-200">{gettext("stale")}</span>
          </div>
          <button phx-click="pin" phx-target={@myself} phx-value-name={row.name} class={btn_ghost()}>{gettext("Pin")}</button>
        </div>
      </div>

      <div :if={@archived != []} class="mt-4">
        <div class="mb-1 text-sm font-medium text-zinc-300">{gettext("Archived")}</div>
        <div :for={a <- @archived} class="flex items-center justify-between gap-3 rounded-lg px-2 py-1 text-sm hover:bg-zinc-900">
          <div class="min-w-0 truncate">
            <span class="font-medium text-zinc-200">{a.name}</span>
            <span class="ml-2 text-zinc-500">{gettext("archived by %{who}", who: a.by)}</span>
          </div>
          <button phx-click="restore" phx-target={@myself} phx-value-name={a.name} class={btn_ghost()}>{gettext("Restore")}</button>
        </div>
      </div>

      <div :if={@changes != []} class="mt-4">
        <div class="mb-1 text-sm font-medium text-zinc-300">{gettext("Recent changes to skills")}</div>
        <div :for={e <- @changes} class="flex items-center justify-between gap-3 rounded-lg px-2 py-1 text-sm hover:bg-zinc-900">
          <div class="min-w-0 truncate text-zinc-400">
            <span class="font-medium text-zinc-200">{e.skill}</span>
            <span class="ml-2">{e.action}</span>
            <span class="ml-2 text-zinc-500">{gettext("by %{who}", who: e.actor)}</span>
          </div>
          <button phx-click="undo" phx-target={@myself} phx-value-id={e.id} class={btn_ghost()}>{gettext("Undo")}</button>
        </div>
      </div>
    </div>
    """
  end

  defp number_fields do
    [
      {"interval_hours", gettext("Run every (hours)")},
      {"min_idle_hours", gettext("Only when idle (hours)")},
      {"stale_after_days", gettext("Stale after (days)")},
      {"archive_after_days", gettext("Archive after (days)")}
    ]
  end

  defp headline(%{enabled: false}), do: gettext("off")
  defp headline(%{paused: true}), do: gettext("paused")
  defp headline(_), do: gettext("on")

  defp pill_cls(%{enabled: true, paused: false}), do: "bg-emerald-900/40 text-emerald-300"
  defp pill_cls(_), do: "bg-zinc-800 text-zinc-400"

  defp last_run(%{last_run_at: nil}), do: gettext("never")
  defp last_run(%{last_run_at: at, last_run_summary: summary}), do: "#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC, #{summary}"

  defp next_run(%{next_run_at: nil}), do: gettext("none scheduled")
  defp next_run(%{next_run_at: at}), do: "#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC"

  @impl true
  def handle_event("run", _params, socket), do: {:noreply, start_run(socket, :run)}
  def handle_event("preview", _params, socket), do: {:noreply, start_run(socket, :preview)}

  def handle_event("pause", _params, socket) do
    State.set_paused(true)
    {:noreply, load(socket)}
  end

  def handle_event("resume", _params, socket) do
    State.set_paused(false)
    {:noreply, load(socket)}
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, result: nil)}

  def handle_event("save_settings", params, socket) do
    values =
      ~w(interval_hours min_idle_hours stale_after_days archive_after_days)
      |> Map.new(&{&1, params[&1]})
      |> Map.merge(%{"enabled" => params["enabled"] == "true", "consolidate" => params["consolidate"] == "true"})

    case apply_settings(values) do
      :ok -> notify(:info, gettext("Curator settings saved."))
      {:error, message} -> notify(:error, message)
    end

    {:noreply, load(socket)}
  end

  def handle_event("restore", %{"name" => name}, socket) do
    case Lifecycle.restore(name, @actor) do
      {:ok, _} -> notify(:info, gettext("Restored %{name}.", name: name))
      {:error, _} -> notify(:error, gettext("Could not restore %{name}.", name: name))
    end

    {:noreply, load(socket)}
  end

  def handle_event("undo", %{"id" => id}, socket) do
    case Manage.undo(id, @actor) do
      {:ok, result} -> notify(:info, result.message)
      {:error, message} -> notify(:error, message)
    end

    {:noreply, load(socket)}
  end

  def handle_event("pin", %{"name" => name}, socket) do
    case Lifecycle.pin(name, true, @actor) do
      :ok -> notify(:info, gettext("Pinned %{name}: only you can change it now.", name: name))
      {:error, message} -> notify(:error, message)
    end

    {:noreply, load(socket)}
  end

  defp start_run(socket, kind) do
    socket
    |> assign(running: kind, result: nil)
    |> start_async(:curator_run, fn -> Curator.run(dry_run: kind == :preview) end)
  end

  @impl true
  def handle_async(:curator_run, {:ok, {:ok, report}}, socket) do
    title = if report["dry_run"], do: gettext("Preview: nothing was changed"), else: gettext("Run finished")
    text = [report["summary"], get_in(report, ["consolidation", "model_summary"])] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
    {:noreply, socket |> assign(running: nil, result: %{title: title, text: text}) |> load()}
  end

  def handle_async(:curator_run, _failed, socket) do
    notify(:error, gettext("The curator could not run."))
    {:noreply, socket |> assign(running: nil) |> load()}
  end

  # Widening a threshold before narrowing the other keeps `stale <= archive` true at every step.
  defp apply_settings(values) do
    order =
      if to_int(values["archive_after_days"]) >= Settings.archive_after_days(),
        do: ~w(archive_after_days stale_after_days),
        else: ~w(stale_after_days archive_after_days)

    keys = order ++ ~w(interval_hours min_idle_hours enabled consolidate)
    Enum.reduce_while(keys, :ok, fn key, :ok -> continue(Settings.put(key, values[key])) end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _} = error), do: {:halt, error}

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp notify(kind, message) do
    send(self(), {:flash, kind, message})
    :ok
  end
end
