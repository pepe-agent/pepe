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

  alias Ecto.Changeset
  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Companies",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       editing: nil,
       form: company_form("")
     )}
  end

  defp company_changeset(name) do
    {%{}, %{name: :string}}
    |> Changeset.cast(%{"name" => name}, [:name])
    |> Changeset.validate_required([:name])
  end

  defp company_form(name), do: to_form(company_changeset(name), as: :company)

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
          <button :if={!@editing} phx-click="company_new" class={btn()}>{gettext("+ New company")}</button>
          <button :if={@editing} phx-click="company_cancel" class={btn_ghost()}>&larr; {gettext("Back to companies")}</button>
        </.view_header>

        <div class="flex-1 overflow-y-auto p-6">
          <div :if={!@editing} class="space-y-3">
          <div :for={name <- @companies} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{name}</span>
                <span class="ml-2 text-sm text-zinc-500">{gettext("%{count} agents", count: length(Config.agents_in(name)))}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
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
            <div class="mt-1 flex items-center gap-2 text-sm">
              <span :if={desc_of(name)} class="text-zinc-400">{desc_of(name)}</span>
              <span :if={Config.company_markup(name) != 1.0} class="rounded bg-amber-800/40 px-1.5 text-amber-200">
                {gettext("markup ×%{m}", m: Config.company_markup(name))}
              </span>
            </div>
          </div>
          <p :if={@companies == []} class="text-[15px] text-zinc-500">
            {gettext("No companies yet. Everything lives in the root workspace. Create one to isolate a client or team.")}
          </p>
          </div>

          <div :if={@editing} class="max-w-2xl">
            <.form for={@form} phx-submit="company_save" class="space-y-4">
              <div class="text-lg font-semibold">
                {if @editing.new?, do: gettext("+ New company"), else: gettext("Edit %{name}", name: @editing.name)}
              </div>
              <div :if={@form.errors != []} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
                {gettext("Please fix the errors below.")}
              </div>
              <div>
                <.input field={@form[:name]} label={gettext("Name")} placeholder="acme" />
                <p class={hlp()}>
                  {if @editing.new?,
                    do:
                      gettext("Letters, digits, - and _ only. Becomes the prefix for its agents (e.g. acme/sales)."),
                    else:
                      gettext("This name keys every agent, model, route, automation, token and file. Changing it re-keys them all.")}
                </p>
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Description")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="company[description]" value={@editing.description} placeholder={gettext("Acme Inc, sales team")} class={fld()} />
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Billing markup")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="company[markup]" value={@editing.markup} placeholder="1.3" inputmode="decimal" class={fld()} />
                <p class={hlp()}>
                  {gettext("Multiplier applied to provider cost to get the amount to bill (e.g. 1.3 = +30%). Blank = bill exactly the provider cost.")}
                </p>
              </div>
              <div class="flex gap-2 border-t border-zinc-800 pt-4">
                <button type="submit" class={btn()}>{gettext("Save")}</button>
                <button type="button" phx-click="company_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
              </div>
            </.form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("company_new", _p, socket),
    do:
      {:noreply,
       assign(socket,
         editing: %{new?: true, name: "", description: "", markup: ""},
         form: company_form("")
       )}

  def handle_event("company_edit", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       editing: %{
         new?: false,
         name: name,
         description: desc_of(name) || "",
         markup: markup_field(name)
       },
       form: company_form(name)
     )}
  end

  def handle_event("company_cancel", _p, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("company_save", %{"company" => p}, socket) do
    cs = company_changeset(p["name"] || "")

    cond do
      not cs.valid? ->
        {:noreply, assign(socket, form: to_form(%{cs | action: :validate}, as: :company))}

      socket.assigns.editing.new? ->
        create_company(p, socket)

      true ->
        edit_company(p, socket)
    end
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

  defp create_company(p, socket) do
    name = String.trim(p["name"] || "")

    meta =
      %{}
      |> put_if(blank(p["description"]), "description")
      |> put_if(parse_markup(p["markup"]), "markup")

    case Config.add_company(name, meta) do
      :ok ->
        {:noreply,
         socket
         |> assign(companies: Config.companies(), editing: nil)
         |> put_flash(:info, gettext("Company %{name} created.", name: name))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That company already exists."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid name. Use letters, digits, - and _."))}
    end
  end

  # Save an edit: if the name changed, re-key everything (rename), then update the meta.
  defp edit_company(p, socket) do
    old = socket.assigns.editing.name
    new = String.trim(p["name"] || "")
    meta = %{"description" => blank(p["description"]), "markup" => parse_markup(p["markup"])}

    case maybe_rename(old, new) do
      :ok ->
        Config.update_company(new, meta)

        {:noreply,
         socket
         |> assign(companies: Config.companies(), editing: nil)
         |> put_flash(:info, save_flash(old, new))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That company already exists."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid name. Use letters, digits, - and _."))}
    end
  end

  defp maybe_rename(old, old), do: :ok
  defp maybe_rename(old, new), do: Config.rename_company(old, new)

  defp save_flash(old, old), do: gettext("Company %{name} updated.", name: old)
  defp save_flash(old, new), do: gettext("Company %{old} renamed to %{new}.", old: old, new: new)

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
