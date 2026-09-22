defmodule PepeWeb.SkillsLive do
  @moduledoc """
  Skills section: every skill the catalog knows, whether an agent is offered it and, when not,
  why; what it still needs on this machine; the result of the specification check; and the
  switches an operator has (off everywhere, or off on one channel).

  Deciding whether a repository's own skills, a shared directory, or inline shell commands are
  trusted stays in the terminal (`mix pepe skill trust`, `external`, `set inline-shell`): those
  widen what an agent will follow, so they are not one click away in a browser tab.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Readiness
  alias Pepe.Skills.Settings
  alias Pepe.Skills.Validate

  # The first segment of a session key: what a skill switched off for one channel is keyed by.
  @channels ~w(telegram web tui acp api webhook)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Skills",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       reports: %{},
       skills: load()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="skills" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="📚"
          title={gettext("Skills")}
          desc={gettext("Step-by-step know-how an agent reads when a request calls for it. Each one shows whether agents are offered it, and if not, why. Switch one off everywhere or on a single channel. Install and create skills from chat or with mix pepe skill.")}
        />
        <div class="flex-1 space-y-3 overflow-y-auto p-4 sm:p-6">
          <div :if={@skills == []} class="text-[15px] text-zinc-500">{gettext("No skills found.")}</div>
          <div :for={row <- @skills} class={card()}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0">
                <span class="font-medium">{row.skill.name}</span>
                <span class="ml-2 rounded bg-zinc-700 px-1.5 text-sm text-zinc-300">{tier_label(row.skill.source)}</span>
                <span :if={row.hidden} class="ml-1 rounded bg-amber-700 px-1.5 text-sm">{hidden_label(row.hidden)}</span>
                <span :if={row.needs} class="ml-1 rounded bg-zinc-800 px-1.5 text-sm text-amber-400">{row.needs}</span>
              </div>
              <div class="flex shrink-0 flex-wrap gap-1 text-sm">
                <button phx-click="skill_check" phx-value-name={row.skill.name} class={btn_ghost()}>{gettext("Check")}</button>
                <button
                  :if={!row.off}
                  phx-click="skill_off"
                  phx-value-name={row.skill.name}
                  class={btn_ghost()}
                >
                  {gettext("Turn off")}
                </button>
                <button :if={row.off} phx-click="skill_on" phx-value-name={row.skill.name} class={btn_ghost()}>
                  {gettext("Turn on")}
                </button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">{row.skill.summary}</div>
            <div class="mt-2 flex flex-wrap items-center gap-1.5 text-sm text-zinc-500">
              <span :if={row.off_on != []}>{gettext("Off on:")}</span>
              <button
                :for={channel <- row.off_on}
                phx-click="skill_channel_on"
                phx-value-name={row.skill.name}
                phx-value-channel={channel}
                title={gettext("Turn on again")}
                class="rounded bg-zinc-800 px-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                {channel_label(channel)} ✕
              </button>
              <form id={"skill-channel-#{row.skill.name}"} phx-submit="skill_channel_off" class="flex items-center gap-1">
                <input type="hidden" name="name" value={row.skill.name} />
                <select name="channel" class={[fld_sm(), "w-auto"]}>
                  <option :for={channel <- channels() -- row.off_on} value={channel}>{channel_label(channel)}</option>
                </select>
                <button class={btn_ghost()}>{gettext("Turn off there")}</button>
              </form>
            </div>
            <.report :if={@reports[row.skill.name]} report={@reports[row.skill.name]} />
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("skill_off", %{"name" => name}, socket), do: {:noreply, switch(socket, fn -> Settings.disable(name, nil) end)}
  def handle_event("skill_on", %{"name" => name}, socket), do: {:noreply, switch(socket, fn -> Settings.enable(name, nil) end)}

  def handle_event("skill_channel_off", %{"name" => name, "channel" => channel}, socket) when channel in @channels,
    do: {:noreply, switch(socket, fn -> Settings.disable(name, channel) end)}

  def handle_event("skill_channel_on", %{"name" => name, "channel" => channel}, socket) when channel in @channels,
    do: {:noreply, switch(socket, fn -> Settings.enable(name, channel) end)}

  def handle_event("skill_check", %{"name" => name}, socket) do
    case Validate.run(name) do
      {:ok, report} -> {:noreply, assign(socket, reports: Map.put(socket.assigns.reports, name, report))}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, gettext("No skill named %{name}", name: name))}
    end
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/skills")}

  def handle_event("toggle_new_project", _p, socket), do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  defp switch(socket, fun) do
    fun.()
    assign(socket, skills: load())
  end

  # Everything the catalog holds, each with what is off for it and where, and what it still needs.
  defp load do
    off = Settings.disabled()

    for %{skill: skill, readiness: readiness} = row <- Catalog.status() do
      row
      |> Map.put(:off, skill.name in off)
      |> Map.put(:off_on, Enum.filter(@channels, &(skill.name in Settings.channel_disabled(&1))))
      |> Map.put(:needs, Readiness.note(readiness))
    end
  end

  defp channels, do: @channels

  attr :report, :map, required: true

  defp report(assigns) do
    ~H"""
    <div class="mt-2 text-sm">
      <div class={if @report.valid?, do: "text-green-400", else: "text-red-400"}>{report_line(@report)}</div>
      <pre :if={@report.findings != []} class="mt-1 overflow-x-auto whitespace-pre-wrap text-zinc-400">{Validate.format(@report.findings)}</pre>
    </div>
    """
  end

  defp report_line(%{valid?: true, warnings: 0}), do: gettext("Valid: nothing to report.")

  defp report_line(%{valid?: true, warnings: warnings}),
    do: ngettext("Valid, with %{count} warning.", "Valid, with %{count} warnings.", warnings, count: warnings)

  defp report_line(%{errors: errors}),
    do: ngettext("Not valid: %{count} error.", "Not valid: %{count} errors.", errors, count: errors)

  defp tier_label(:project), do: gettext("Project")
  defp tier_label(:user), do: gettext("Yours")
  defp tier_label(:external), do: gettext("Shared folder")
  defp tier_label(:builtin), do: gettext("Built in")

  defp hidden_label(:disabled), do: gettext("Off")
  defp hidden_label(:platform), do: gettext("For another operating system")
  defp hidden_label(:environment), do: gettext("For another environment")
  defp hidden_label(:channel), do: gettext("For other channels")
  defp hidden_label({:requires_tools, tools}), do: gettext("Needs the %{tools} tool", tools: Enum.join(tools, ", "))
  defp hidden_label({:fallback_for_tools, tools}), do: gettext("Not needed while %{tools} is available", tools: Enum.join(tools, ", "))

  defp channel_label("telegram"), do: "Telegram"
  defp channel_label("web"), do: gettext("Dashboard chat")
  defp channel_label("tui"), do: gettext("Console")
  defp channel_label("acp"), do: gettext("Editor")
  defp channel_label("api"), do: "API"
  defp channel_label("webhook"), do: gettext("Webhook channels")
end
