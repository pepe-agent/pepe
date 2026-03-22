defmodule PepeWeb.IntegrationsLive do
  @moduledoc """
  Integrations section: connect channel plugins (Chatwoot, ...) to your agents. Each
  plugin provider declares a `config_schema/0`, and this page renders the connection
  form generically from it, so a new provider needs no new screen. A connection is a
  webhook entry (see `Pepe.Webhooks`) bound to an agent; its inbound URL goes into the
  provider's outgoing/webhook setting.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Webhooks

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Integrations",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       providers: plugin_providers(),
       adding: nil,
       editing_slug: nil,
       form_label: nil,
       form_schema: [],
       form_values: %{},
       form_errors: %{}
     )
     |> load()}
  end

  defp load(socket), do: assign(socket, webhooks: Config.webhooks())

  # Plugin providers that declare a config_schema (built-ins without one are excluded).
  defp plugin_providers do
    Webhooks.providers()
    |> Enum.map(fn name -> {name, Webhooks.provider(name)} end)
    |> Enum.filter(fn {_name, mod} -> mod && function_exported?(mod, :config_schema, 0) end)
    |> Enum.map(fn {name, mod} ->
      %{name: name, label: provider_label(mod, name), schema: mod.config_schema()}
    end)
  end

  defp provider_label(mod, name),
    do: if(function_exported?(mod, :label, 0), do: mod.label(), else: name)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="integrations" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔌"
          title={gettext("Integrations")}
          desc={gettext("Connect channel plugins to your agents. Each provider's fields come from the plugin itself; fill them in, then paste the webhook URL into the provider.")}
        >
          <button :if={@adding != nil} phx-click="cancel" class={btn_ghost()}>&larr; {gettext("Back to integrations")}</button>
        </.view_header>

        <div class="min-h-0 flex-1 overflow-y-auto p-6">
          <%= if @adding do %>
            {form_view(assigns)}
          <% else %>
            {list_view(assigns)}
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # ---- list of providers and their connections ---------------------------------------

  defp list_view(assigns) do
    ~H"""
    <div :if={@providers == []} class="max-w-3xl rounded-xl border border-dashed border-zinc-800 p-10 text-center text-zinc-500">
      <p>{gettext("No channel plugins installed yet.")}</p>
      <p class="mt-2">
        {gettext("Install one, then reload this page:")}
        <code class="text-zinc-300">mix pepe plugin install</code>
      </p>
      <p class="mt-1 text-sm text-zinc-600">{gettext("See the Plugins docs for the available providers.")}</p>
    </div>

    <div :if={@providers != []} class="max-w-3xl space-y-8">
      <div :for={p <- @providers}>
        <div class="mb-2 flex items-center justify-between gap-2">
          <div class="flex items-center gap-2 font-medium">
            <span>{p.label}</span>
            <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-xs text-zinc-400">{p.name}</span>
          </div>
          <button phx-click="new" phx-value-name={p.name} class={btn()}>{gettext("+ New connection")}</button>
        </div>

        <div :for={{slug, e} <- conns_for(@webhooks, p.name)} class={[card(), "mb-2"]}>
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0">
              <span class="font-medium">{slug}</span>
              <span class={["ml-2 rounded px-1.5 text-sm", (e["mode"] == "admin" && "bg-indigo-700") || "bg-zinc-700 text-zinc-300"]}>
                {e["mode"] || "support"}
              </span>
            </div>
            <div class="flex shrink-0 gap-1 text-sm">
              <button phx-click="edit" phx-value-slug={slug} class={btn_ghost()}>{gettext("Edit")}</button>
              <button
                phx-click="delete"
                phx-value-slug={slug}
                data-confirm={gettext("Remove connection %{slug}?", slug: slug)}
                class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
              >✕</button>
            </div>
          </div>
          <div class="mt-1 text-sm text-zinc-400">{gettext("agent:")} {e["agent"] || gettext("(default)")}</div>
          <div class="mt-2 text-sm text-zinc-500">
            {gettext("Webhook URL")}:
            <code class="break-all text-zinc-300">{webhook_url(e["company"], p.name, slug)}</code>
          </div>
          <p class="mt-1 text-xs text-zinc-600">{gettext("Paste this into the provider as its outgoing webhook URL.")}</p>
        </div>

        <p :if={conns_for(@webhooks, p.name) == []} class="text-sm text-zinc-500">{gettext("No connections yet.")}</p>
      </div>
    </div>
    """
  end

  # ---- the connection form (schema-driven) -------------------------------------------

  defp form_view(assigns) do
    ~H"""
    <div class="max-w-2xl">
      <form phx-submit="save" class="space-y-4">
        <div class="text-lg font-semibold">
          {(@editing_slug && gettext("Edit %{p} connection", p: @form_label)) ||
            gettext("New %{p} connection", p: @form_label)}
        </div>

        <div :if={@form_errors != %{}} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
          {gettext("Please fix the errors below.")}
        </div>

        <div>
          <label class={lbl()}>{gettext("Slug (URL id)")}</label>
          <input name="slug" value={fval(@form_values, "slug")} class={fld()} placeholder="support" />
          <p :if={@form_errors["slug"]} class="mt-1.5 text-sm text-red-400">{@form_errors["slug"]}</p>
          <p :if={!@form_errors["slug"]} class={hlp()}>{gettext("A unique id used in the webhook URL.")}</p>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class={lbl()}>{gettext("Company")}</label>
            <select name="company" class={fld()}>
              <option value="root" selected={fval(@form_values, "company") in ["", "root"]}>{gettext("Root (no company)")}</option>
              <option :for={c <- @companies} value={c} selected={fval(@form_values, "company") == c}>{c}</option>
            </select>
          </div>
          <div>
            <label class={lbl()}>{gettext("Mode")}</label>
            <select name="mode" class={fld()}>
              <option value="support" selected={fval(@form_values, "mode") != "admin"}>{gettext("support (customer-facing)")}</option>
              <option value="admin" selected={fval(@form_values, "mode") == "admin"}>{gettext("admin (yours)")}</option>
            </select>
          </div>
        </div>

        <div>
          <label class={lbl()}>{gettext("This connection talks to")}</label>
          <select name="agent" class={fld()}>
            <option value="">{gettext("choose an agent")}</option>
            <option :for={a <- scoped_agent_names(@scope)} value={a} selected={fval(@form_values, "agent") == a}>{a}</option>
          </select>
          <p :if={@form_errors["agent"]} class="mt-1.5 text-sm text-red-400">{@form_errors["agent"]}</p>
        </div>

        <div class="space-y-4 border-t border-zinc-800 pt-4">
          <div :for={f <- @form_schema}>
            <label class={lbl()}>{f["label"]}</label>
            <select :if={f["type"] == "select"} name={"cfg[" <> f["key"] <> "]"} class={fld()}>
              <option :for={o <- f["options"] || []} value={o} selected={cfgval(@form_values, f["key"]) == o}>{o}</option>
            </select>
            <input
              :if={f["type"] != "select"}
              name={"cfg[" <> f["key"] <> "]"}
              value={cfgval(@form_values, f["key"])}
              class={[fld(), f["type"] == "secret" && "font-mono"]}
            />
            <p :if={f["hint"]} class={hlp()}>{f["hint"]}</p>
            <p :if={f["type"] == "secret"} class={hlp()}>
              {gettext("Secret: you can write ${ENV_VAR} to keep it out of the config file.")}
            </p>
          </div>
        </div>

        <div class="flex gap-2 border-t border-zinc-800 pt-4">
          <button type="submit" class={btn()}>{gettext("Save connection")}</button>
          <button type="button" phx-click="cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
        </div>
      </form>
    </div>
    """
  end

  # ---- events ------------------------------------------------------------------------

  @impl true
  def handle_event("new", %{"name" => name}, socket) do
    case find_provider(socket.assigns.providers, name) do
      nil ->
        {:noreply, socket}

      p ->
        default_company = if socket.assigns.scope in [nil, "all", "root"], do: "root", else: socket.assigns.scope

        {:noreply,
         assign(socket,
           adding: name,
           editing_slug: nil,
           form_label: p.label,
           form_schema: p.schema,
           form_values: %{"company" => default_company, "mode" => "support"},
           form_errors: %{}
         )}
    end
  end

  def handle_event("edit", %{"slug" => slug}, socket) do
    entry = Config.get_webhook(slug) || %{}
    name = entry["provider"]

    case find_provider(socket.assigns.providers, name) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This connection's provider is not installed."))}

      p ->
        values = %{
          "slug" => slug,
          "company" => entry["company"] || "root",
          "agent" => entry["agent"] || "",
          "mode" => entry["mode"] || "support",
          "cfg" => entry["config"] || %{}
        }

        {:noreply,
         assign(socket,
           adding: name,
           editing_slug: slug,
           form_label: p.label,
           form_schema: p.schema,
           form_values: values,
           form_errors: %{}
         )}
    end
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    Config.delete_webhook(slug)
    {:noreply, socket |> load() |> put_flash(:info, gettext("Removed connection %{s}.", s: slug))}
  end

  def handle_event("cancel", _p, socket) do
    {:noreply, assign(socket, adding: nil, editing_slug: nil, form_values: %{}, form_errors: %{})}
  end

  def handle_event("save", params, socket) do
    name = socket.assigns.adding
    schema = socket.assigns.form_schema
    slug = String.trim(params["slug"] || "")
    agent = blank(params["agent"])
    editing = socket.assigns.editing_slug

    errors =
      %{}
      |> maybe_error("slug", slug == "" && gettext("A slug is required."))
      |> maybe_error("slug", slug != "" && slug != editing && Config.webhook_exists?(slug) && gettext("This slug is already in use."))
      |> maybe_error("agent", is_nil(agent) && gettext("Choose an agent."))

    if errors == %{} do
      entry =
        reject_nil(%{
          "provider" => name,
          "company" => company_value(params["company"]),
          "agent" => agent,
          "mode" => (params["mode"] == "admin" && "admin") || "support",
          "config" => build_config(schema, params["cfg"] || %{})
        })

      if editing && editing != slug, do: Config.delete_webhook(editing)
      Config.put_webhook(slug, entry)

      {:noreply,
       socket
       |> assign(adding: nil, editing_slug: nil, form_values: %{}, form_errors: %{})
       |> load()
       |> put_flash(:info, gettext("Saved connection %{s}.", s: slug))}
    else
      {:noreply,
       socket
       |> assign(form_values: params, form_errors: errors)
       |> put_flash(:error, gettext("Please fix the errors below."))}
    end
  end

  # sidebar scope events (shared shape with the other sections)
  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/integrations")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  # ---- helpers -----------------------------------------------------------------------

  defp find_provider(providers, name), do: Enum.find(providers, &(&1.name == name))

  defp conns_for(webhooks, name) do
    webhooks
    |> Enum.filter(fn {_slug, e} -> e["provider"] == name end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # "root"/blank means the no-company scope (stored as absent, like WhatsApp connections).
  defp company_value(c) when c in [nil, "", "root"], do: nil
  defp company_value(c), do: c

  defp build_config(schema, cfg) do
    Enum.reduce(schema, %{}, fn f, acc ->
      case blank(Map.get(cfg, f["key"])) do
        nil -> acc
        v -> Map.put(acc, f["key"], v)
      end
    end)
  end

  defp maybe_error(errors, _field, false), do: errors
  defp maybe_error(errors, _field, nil), do: errors
  defp maybe_error(errors, field, msg) when is_binary(msg), do: Map.put_new(errors, field, msg)

  defp fval(values, key), do: to_string(Map.get(values, key, ""))
  defp cfgval(values, key), do: to_string(get_in(values, ["cfg", key]) || "")

  defp webhook_url(company, provider, slug),
    do: "#{webhook_host()}/webhooks/#{company || "root"}/#{provider}/#{slug}"

  defp webhook_host, do: System.get_env("PEPE_PUBLIC_URL") || "https://YOUR_HOST"
end
