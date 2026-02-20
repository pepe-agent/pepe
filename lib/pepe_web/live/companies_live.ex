defmodule PepeWeb.CompaniesLive do
  @moduledoc """
  Companies section: create, edit, rename and delete tenant scopes. Each company
  walls off its own agents, workspaces, models and automations from every other.
  Root is the default, non-company workspace. A company's name is its identity key
  (it prefixes every agent handle); renaming re-keys everything that references it.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Companies",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       editing: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="companies" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🏢"
          title={gettext("Companies")}
          desc={gettext("A company is an isolated workspace (tenant): its agents, models and automations are walled off from every other. Root is the default, non-company workspace.")}
        >
          <button phx-click="company_new" class={btn()}>{gettext("+ New company")}</button>
        </.view_header>

        <div class="flex-1 space-y-3 overflow-y-auto p-6">
          <div :for={name <- @companies} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{name}</span>
                <span class="ml-2 text-xs text-zinc-500">{gettext("%{count} agents", count: length(Config.agents_in(name)))}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-xs">
                <.link navigate={~p"/agents?scope=#{name}"} class={btn_ghost()}>{gettext("Open")}</.link>
                <button phx-click="company_edit" phx-value-name={name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button
                  phx-click="company_delete"
                  phx-value-name={name}
                  data-confirm={gettext("Delete company %{name} and its %{count} agents? Their workspaces stay on disk.", name: name, count: length(Config.agents_in(name)))}
                  class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
                >
                  {gettext("Delete")}
                </button>
              </div>
            </div>
            <div class="mt-1 flex items-center gap-2 text-xs">
              <span :if={desc_of(name)} class="text-zinc-400">{desc_of(name)}</span>
              <span :if={Config.company_markup(name) != 1.0} class="rounded bg-amber-800/40 px-1.5 text-amber-200">
                {gettext("markup ×%{m}", m: Config.company_markup(name))}
              </span>
            </div>
          </div>
          <p :if={@companies == []} class="text-sm text-zinc-500">
            {gettext("No companies yet — everything lives in the root workspace. Create one to isolate a client or team.")}
          </p>

          <form :if={@editing} phx-submit="company_save" class="space-y-4 rounded-xl border border-blue-900/60 bg-blue-950/10 p-5">
            <div class="text-sm font-medium">
              {if @editing.new?, do: gettext("+ New company"), else: gettext("Edit %{name}", name: @editing.name)}
            </div>
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input
                name="name"
                value={@editing.name}
                placeholder="acme"
                readonly={!@editing.new?}
                class={[fld(), !@editing.new? && "opacity-60"]}
              />
              <p class={hlp()}>
                {if @editing.new?,
                  do:
                    gettext(
                      "Letters, digits, - and _ only. Becomes the prefix for its agents (e.g. acme/sales)."
                    ),
                  else:
                    gettext(
                      "This name keys every agent, workspace and binding — use Rename below to change it safely."
                    )}
              </p>
            </div>
            <div>
              <label class={lbl()}>
                {gettext("Description")} <span class="text-zinc-600">{gettext("(optional)")}</span>
              </label>
              <input
                name="description"
                value={@editing.description}
                placeholder={gettext("Acme Inc — sales team")}
                class={fld()}
              />
            </div>
            <div>
              <label class={lbl()}>
                {gettext("Billing markup")} <span class="text-zinc-600">{gettext("(optional)")}</span>
              </label>
              <input name="markup" value={@editing.markup} placeholder="1.3" inputmode="decimal" class={fld()} />
              <p class={hlp()}>
                {gettext("Multiplier applied to provider cost to get the amount to bill (e.g. 1.3 = +30%). Blank = bill exactly the provider cost.")}
              </p>
            </div>
            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="company_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>

          <form :if={@editing && !@editing.new?} phx-submit="company_rename"
            class="space-y-3 rounded-xl border border-amber-900/50 bg-amber-950/10 p-5">
            <div class="text-sm font-medium">{gettext("Rename company")}</div>
            <input type="hidden" name="old" value={@editing.name} />
            <div>
              <input name="new" placeholder={gettext("new name")} class={fld()} />
              <p class={hlp()}>
                {gettext("Re-keys all of this company's agents, models, routes, automations, tokens and files to the new name. Free text (prompts, descriptions) is left as-is.")}
              </p>
            </div>
            <button type="submit" class={[btn(), "bg-amber-700 hover:bg-amber-600"]}>{gettext("Rename")}</button>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("company_new", _p, socket),
    do: {:noreply, assign(socket, editing: %{new?: true, name: "", description: "", markup: ""})}

  def handle_event("company_edit", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       editing: %{
         new?: false,
         name: name,
         description: desc_of(name) || "",
         markup: markup_field(name)
       }
     )}
  end

  def handle_event("company_cancel", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("company_rename", %{"old" => old, "new" => new}, socket) do
    case Config.rename_company(old, String.trim(new)) do
      :ok ->
        {:noreply,
         socket
         |> assign(companies: Config.companies(), editing: nil)
         |> put_flash(
           :info,
           gettext("Company %{old} renamed to %{new}.", old: old, new: String.trim(new))
         )}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That company already exists."))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("That company no longer exists."))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Invalid name — use letters, digits, - and _."))}
    end
  end

  def handle_event("company_save", params, socket) do
    if socket.assigns.editing && socket.assigns.editing.new?,
      do: create_company(params, socket),
      else: edit_company(params, socket)
  end

  def handle_event("company_delete", %{"name" => name}, socket) do
    Config.delete_company(name, force: true)

    {:noreply,
     socket
     |> assign(companies: Config.companies(), editing: nil)
     |> put_flash(:info, gettext("Company %{name} removed.", name: name))}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/companies")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  defp create_company(params, socket) do
    name = String.trim(params["name"] || "")

    meta =
      %{}
      |> put_if(blank(params["description"]), "description")
      |> put_if(parse_markup(params["markup"]), "markup")

    case Config.add_company(name, meta) do
      :ok ->
        {:noreply,
         socket
         |> assign(companies: Config.companies(), editing: nil)
         |> put_flash(:info, gettext("Company %{name} created.", name: name))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That company already exists."))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Invalid name — use letters, digits, - and _."))}
    end
  end

  defp edit_company(params, socket) do
    name = socket.assigns.editing.name

    Config.update_company(name, %{
      "description" => blank(params["description"]),
      "markup" => parse_markup(params["markup"])
    })

    {:noreply,
     socket
     |> assign(companies: Config.companies(), editing: nil)
     |> put_flash(:info, gettext("Company %{name} updated.", name: name))}
  end

  defp desc_of(name), do: (Config.get_company(name) || %{})["description"]

  # The markup as a form value: blank when unset or the default 1.0.
  defp markup_field(name) do
    case Config.company_markup(name) do
      1.0 -> ""
      m -> to_string(m)
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
