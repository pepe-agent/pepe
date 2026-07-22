defmodule PepeWeb.ProjectsLive do
  @moduledoc """
  Projects section: create, edit, rename and delete tenant scopes. Each project
  walls off its own agents, workspaces, models and automations from every other.
  Root is the default, non-project workspace. A project's name is its identity key
  (it prefixes every agent handle); renaming re-keys everything that references it.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Ecto.Changeset
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Projects",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       editing: nil,
       form: project_form("")
     )
     |> refresh_usage()}
  end

  # The Pepe.Usage.* calls (month_to_date, over_budget?, ...) each read the token ledger - real
  # I/O, unlike the Config.* budget/markup/limit reads beside them in the template, which are cheap
  # in-memory map lookups off Config's own cache. Computed once here into `@usage`, keyed by "root"
  # and each project name, instead of being called straight from the template - which used to mean
  # every one of them ran again on EVERY re-render (any assign changing, any event), not just when
  # the numbers could actually have changed. Refreshed after mount and after every event that can
  # change either which projects exist or their usage numbers.
  defp refresh_usage(socket) do
    usage = Map.new(["root" | socket.assigns.projects], &{&1, usage_snapshot(event_scope(&1))})
    assign(socket, usage: usage)
  end

  defp usage_snapshot(scope) do
    %{
      over_budget: Pepe.Usage.over_budget?(scope),
      near_budget: Pepe.Usage.near_budget?(scope),
      month_to_date: Pepe.Usage.month_to_date(scope),
      budget_reset_at: Pepe.Usage.budget_reset_at(scope),
      over_message_limit: Pepe.Usage.over_message_limit?(scope),
      message_count: Pepe.Usage.message_count_month_to_date(scope),
      messages_reset_at: Pepe.Usage.messages_reset_at(scope)
    }
  end

  defp project_changeset(name) do
    {%{}, %{name: :string}}
    |> Changeset.cast(%{"name" => name}, [:name])
    |> Changeset.validate_required([:name])
  end

  defp project_form(name), do: to_form(project_changeset(name), as: :project)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="projects" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🏢"
          title={gettext("Projects")}
          desc={gettext("A project is an isolated workspace (tenant): its agents, models and automations are walled off from every other. Principal is the default, non-project workspace.")}
        >
          <button :if={!@editing} phx-click="project_new" class={btn()}>{gettext("+ New project")}</button>
          <button :if={@editing} phx-click="project_cancel" class={btn_ghost()}>&larr; {gettext("Back to projects")}</button>
        </.view_header>

        <div class="flex-1 overflow-y-auto p-6">
          <div :if={!@editing} class="space-y-3">
          <div class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{gettext("Principal")}</span>
                <span class="ml-2 text-sm text-zinc-500">{gettext("%{count} agents", count: length(Config.agents_in(nil)))}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <.link navigate={~p"/overview?scope=root"} class={btn_ghost()}>{gettext("Open")}</.link>
                <button phx-click="project_edit" phx-value-name="root" class={btn_ghost()}>{gettext("Edit")}</button>
              </div>
            </div>
            <div class="mt-1 flex items-center gap-2 text-sm">
              <span :if={Config.project_markup(nil) != 1.0} class="rounded bg-amber-800/40 px-1.5 text-amber-200">
                {gettext("markup ×%{m}", m: Config.project_markup(nil))}
              </span>
              <span
                :if={Config.project_budget(nil)}
                title={gettext("Operational count toward the cap, not the billable total - see Usage for the real month total, unaffected by resets.")}
                class={[
                  "rounded px-1.5",
                  (@usage["root"].over_budget && "bg-red-800/60 text-red-200") ||
                    (@usage["root"].near_budget && "bg-amber-800/50 text-amber-100") ||
                    "bg-emerald-900/40 text-emerald-200"
                ]}
              >
                {money(@usage["root"].month_to_date, Config.currency())} / {money(Config.project_budget(nil), Config.currency())}
                <span :if={@usage["root"].budget_reset_at} class="text-zinc-500">
                  · {gettext("since %{date}", date: local_datetime(@usage["root"].budget_reset_at, "%m/%d"))}
                </span>
              </span>
              <button
                :if={Config.project_budget(nil)}
                phx-click="project_reset_budget"
                phx-value-name="root"
                data-confirm={gettext("Reset the principal scope's spend count (currently %{n}) for the rest of this month?", n: money(@usage["root"].month_to_date, Config.currency()))}
                class="text-xs font-medium text-zinc-500 hover:text-zinc-300"
              >
                {gettext("reset")}
              </button>
              <span
                :if={Config.project_message_limit(nil)}
                title={gettext("Operational count toward the cap, not necessarily every message this month if it's been reset.")}
                class={[
                  "rounded px-1.5",
                  (@usage["root"].over_message_limit && "bg-red-800/60 text-red-200") ||
                    "bg-emerald-900/40 text-emerald-200"
                ]}
              >
                {gettext("%{used}/%{limit} msgs/mo", used: @usage["root"].message_count, limit: Config.project_message_limit(nil))}
                <span :if={@usage["root"].messages_reset_at} class="text-zinc-500">
                  · {gettext("since %{date}", date: local_datetime(@usage["root"].messages_reset_at, "%m/%d"))}
                </span>
              </span>
              <button
                :if={Config.project_message_limit(nil)}
                phx-click="project_reset_messages"
                phx-value-name="root"
                data-confirm={gettext("Reset the principal scope's message count (currently %{n}) for the rest of this month?", n: @usage["root"].message_count)}
                class="text-xs font-medium text-zinc-500 hover:text-zinc-300"
              >
                {gettext("reset")}
              </button>
            </div>
          </div>
          <div :for={name <- @projects} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{name}</span>
                <span class="ml-2 text-sm text-zinc-500">{gettext("%{count} agents", count: length(Config.agents_in(name)))}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <.link navigate={~p"/overview?scope=#{name}"} class={btn_ghost()}>{gettext("Open")}</.link>
                <button phx-click="project_edit" phx-value-name={name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button
                  phx-click="project_delete"
                  phx-value-name={name}
                  data-confirm={gettext("Delete project %{name} and its %{count} agents? Their workspaces stay on disk.", name: name, count: length(Config.agents_in(name)))}
                  class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
                >
                  {gettext("Delete")}
                </button>
              </div>
            </div>
            <div class="mt-1 flex items-center gap-2 text-sm">
              <span :if={desc_of(name)} class="text-zinc-400">{desc_of(name)}</span>
              <span :if={Config.project_markup(name) != 1.0} class="rounded bg-amber-800/40 px-1.5 text-amber-200">
                {gettext("markup ×%{m}", m: Config.project_markup(name))}
              </span>
              <span
                :if={Config.project_budget(name)}
                title={gettext("Operational count toward the cap, not the billable total - see Usage for the real month total, unaffected by resets.")}
                class={[
                  "rounded px-1.5",
                  (@usage[name].over_budget && "bg-red-800/60 text-red-200") ||
                    "bg-emerald-900/40 text-emerald-200"
                ]}
              >
                {money(@usage[name].month_to_date, Config.currency())} / {money(Config.project_budget(name), Config.currency())}
                <span :if={@usage[name].budget_reset_at} class="text-zinc-500">
                  · {gettext("since %{date}", date: local_datetime(@usage[name].budget_reset_at, "%m/%d"))}
                </span>
              </span>
              <button
                :if={Config.project_budget(name)}
                phx-click="project_reset_budget"
                phx-value-name={name}
                data-confirm={gettext("Reset %{name}'s spend count (currently %{n}) for the rest of this month?", name: name, n: money(@usage[name].month_to_date, Config.currency()))}
                class="text-xs font-medium text-zinc-500 hover:text-zinc-300"
              >
                {gettext("reset")}
              </button>
              <span
                :if={Config.project_message_limit(name)}
                title={gettext("Operational count toward the cap, not necessarily every message this month if it's been reset.")}
                class={[
                  "rounded px-1.5",
                  (@usage[name].over_message_limit && "bg-red-800/60 text-red-200") ||
                    "bg-emerald-900/40 text-emerald-200"
                ]}
              >
                {gettext("%{used}/%{limit} msgs/mo", used: @usage[name].message_count, limit: Config.project_message_limit(name))}
                <span :if={@usage[name].messages_reset_at} class="text-zinc-500">
                  · {gettext("since %{date}", date: local_datetime(@usage[name].messages_reset_at, "%m/%d"))}
                </span>
              </span>
              <button
                :if={Config.project_message_limit(name)}
                phx-click="project_reset_messages"
                phx-value-name={name}
                data-confirm={gettext("Reset %{name}'s message count (currently %{n}) for the rest of this month?", name: name, n: @usage[name].message_count)}
                class="text-xs font-medium text-zinc-500 hover:text-zinc-300"
              >
                {gettext("reset")}
              </button>
            </div>
          </div>
          <p :if={@projects == []} class="text-[15px] text-zinc-500">
            {gettext("No projects yet. Everything lives in the root workspace. Create one to isolate a client or team.")}
          </p>
          </div>

          <div :if={@editing} class="max-w-2xl">
            <.form for={@form} phx-submit="project_save" class="space-y-4">
              <div class="text-lg font-semibold">
                {cond do
                  @editing.name == "root" -> gettext("Edit Principal")
                  @editing.new? -> gettext("+ New project")
                  true -> gettext("Edit %{name}", name: @editing.name)
                end}
              </div>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <div :if={@editing.name != "root"}>
                <.input field={@form[:name]} label={gettext("Name")} placeholder="acme" />
                <p class={hlp()}>
                  {if @editing.new?,
                    do:
                      gettext("Letters, digits, - and _ only. Becomes the prefix for its agents (e.g. acme/sales)."),
                    else:
                      gettext("This name keys every agent, model, route, automation, token and file. Changing it re-keys them all.")}
                </p>
              </div>
              <div :if={@editing.name != "root"}>
                <label class={lbl()}>
                  {gettext("Description")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="project[description]" value={@editing.description} placeholder={gettext("Acme Inc, sales team")} class={fld()} />
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Billing markup")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="project[markup]" value={@editing.markup} placeholder="1.3" inputmode="decimal" class={fld()} />
                <p class={hlp()}>
                  {gettext("Multiplier applied to provider cost to get the amount to bill (e.g. 1.3 = +30%). Blank = bill exactly the provider cost.")}
                </p>
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Monthly budget")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="project[budget]" value={@editing.budget} placeholder="100" inputmode="decimal" class={fld()} />
                <p class={hlp()}>
                  {gettext("Spend cap for the month in %{currency}. When reached, this project's agents stop making model calls until next month. Blank = no cap.", currency: Config.currency())}
                </p>
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Monthly message limit")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="project[message_limit]" value={@editing.message_limit} placeholder="5000" inputmode="numeric" class={fld()} />
                <p class={hlp()}>
                  {gettext("Cap on customer messages for the month. When reached, this project's agents stop replying until next month (an agent can be exempted individually). Blank = no cap.")}
                </p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Save")}</button>
                <button type="button" phx-click="project_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("project_new", _p, socket),
    do:
      {:noreply,
       assign(socket,
         editing: %{new?: true, name: "", description: "", markup: "", budget: "", message_limit: ""},
         form: project_form("")
       )}

  def handle_event("project_edit", %{"name" => name}, socket) do
    scope = event_scope(name)

    {:noreply,
     assign(socket,
       editing: %{
         new?: false,
         name: name,
         description: desc_of(scope) || "",
         markup: markup_field(scope),
         budget: budget_field(scope),
         message_limit: message_limit_field(scope)
       },
       form: project_form(name)
     )}
  end

  def handle_event("project_cancel", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("project_save", %{"project" => p}, socket) do
    cond do
      socket.assigns.editing.name == "root" ->
        save_root(p, socket)

      not project_changeset(p["name"] || "").valid? ->
        cs = project_changeset(p["name"] || "")
        {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :project))}

      socket.assigns.editing.new? ->
        create_project(p, socket)

      true ->
        edit_project(p, socket)
    end
  end

  def handle_event("project_delete", %{"name" => name}, socket) do
    Config.delete_project(name, force: true)

    {:noreply,
     socket
     |> assign(projects: Config.project_slugs(), editing: nil)
     |> refresh_usage()
     |> put_flash(:info, gettext("Project %{name} removed.", name: name))}
  end

  def handle_event("project_reset_messages", %{"name" => name}, socket) do
    Pepe.Usage.reset_messages(event_scope(name))

    {:noreply,
     socket
     |> refresh_usage()
     |> put_flash(:info, gettext("%{name}'s message count reset for the rest of this month.", name: name))}
  end

  def handle_event("project_reset_budget", %{"name" => name}, socket) do
    Pepe.Usage.reset_budget(event_scope(name))

    {:noreply,
     socket
     |> refresh_usage()
     |> put_flash(:info, gettext("%{name}'s spend count reset for the rest of this month.", name: name))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/projects")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  # The "root" sentinel used throughout this page's markup/events -> the nil scope
  # every Config/Usage function expects (same convention as chat_live/connections_component).
  defp event_scope("root"), do: nil
  defp event_scope(name), do: name

  # Root always "exists" - no create/rename/delete path, just a metadata merge.
  defp save_root(p, socket) do
    meta = %{
      "markup" => parse_markup(p["markup"]),
      "budget" => parse_budget(p["budget"]),
      "message_limit" => parse_message_limit(p["message_limit"])
    }

    Config.update_scope(nil, meta)
    {:noreply, socket |> assign(editing: nil) |> put_flash(:info, gettext("Principal scope updated."))}
  end

  defp create_project(p, socket) do
    name = String.trim(p["name"] || "")

    meta =
      %{}
      |> put_if(blank(p["description"]), "description")
      |> put_if(parse_markup(p["markup"]), "markup")
      |> put_if(parse_budget(p["budget"]), "budget")
      |> put_if(parse_message_limit(p["message_limit"]), "message_limit")

    case Config.add_project(name, meta) do
      :ok ->
        {:noreply,
         socket
         |> assign(projects: Config.project_slugs(), editing: nil)
         |> refresh_usage()
         |> put_flash(:info, gettext("Project %{name} created.", name: name))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That project already exists."))}

      {:error, :slug_has_orphaned_data} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That name still has usage/message/trace history from a different, deleted project. Pick another name.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid name. Use letters, digits, - and _."))}
    end
  end

  # Save an edit: if the name changed, re-key everything (rename), then update the meta.
  defp edit_project(p, socket) do
    old = socket.assigns.editing.name
    new = String.trim(p["name"] || "")

    meta = %{
      "description" => blank(p["description"]),
      "markup" => parse_markup(p["markup"]),
      "budget" => parse_budget(p["budget"]),
      "message_limit" => parse_message_limit(p["message_limit"])
    }

    case maybe_rename(old, new) do
      :ok ->
        Config.update_project(new, meta)

        {:noreply,
         socket
         |> assign(projects: Config.project_slugs(), editing: nil)
         |> refresh_usage()
         |> put_flash(:info, save_flash(old, new))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That project already exists."))}

      {:error, :slug_has_orphaned_data} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That name still has usage/message/trace history from a different, deleted project. Pick another name.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid name. Use letters, digits, - and _."))}
    end
  end

  defp maybe_rename(old, old), do: :ok
  defp maybe_rename(old, new), do: Config.rename_project(old, new)

  defp save_flash(old, old), do: gettext("Project %{name} updated.", name: old)
  defp save_flash(old, new), do: gettext("Project %{old} renamed to %{new}.", old: old, new: new)

  defp desc_of(name), do: (Config.get_project(name) || %{})["description"]

  # The markup as a form value: blank when unset or the default 1.0.
  defp markup_field(name) do
    case Config.project_markup(name) do
      1.0 -> ""
      m -> to_string(m)
    end
  end

  # The monthly budget as a form value: blank when unset.
  defp budget_field(name) do
    case Config.project_budget(name) do
      nil -> ""
      b -> to_string(b)
    end
  end

  # The monthly message limit as a form value: blank when unset.
  defp message_limit_field(name) do
    case Config.project_message_limit(name) do
      nil -> ""
      n -> to_string(n)
    end
  end

  # Parse a message-count cap; only a positive integer is worth storing.
  defp parse_message_limit(value) do
    case value |> to_string() |> String.trim() do
      "" ->
        nil

      s ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end

  # Parse a budget cap; only a positive number is worth storing.
  defp parse_budget(value) do
    case value |> to_string() |> String.trim() |> String.replace(",", ".") do
      "" ->
        nil

      s ->
        case Float.parse(s) do
          {f, _} when f > 0 -> f
          _ -> nil
        end
    end
  end

  # Parse a markup multiplier; only a positive number other than 1 is worth storing.
  defp parse_markup(value) do
    case value |> to_string() |> String.trim() |> String.replace(",", ".") do
      "" ->
        nil

      s ->
        case Float.parse(s) do
          {f, _} when f > 0 and f != 1.0 -> f
          _ -> nil
        end
    end
  end

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)
end
