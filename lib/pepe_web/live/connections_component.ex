defmodule PepeWeb.ConnectionsComponent do
  @moduledoc """
  Shared, schema-driven UI to manage webhook channel connections for a set of
  providers. Given a list of providers (each `%{name, label, schema}`), it renders
  the connections list and a generic add/edit form built from the provider's
  `config_schema/0`. Used by both the Channels page (native channels) and the
  Integrations page (installed plugins) so a new provider needs no new screen.

  It owns its own add/edit/delete/save events (addressed via `phx-target`) and
  reads/writes connections straight from `Pepe.Config`. It reports outcomes to the
  parent LiveView with `send(self(), {:flash, kind, message})`, so the parent only
  needs a matching `handle_info/2`.
  """
  use PepeWeb, :live_component
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  # A parent LiveView can open a provider's form directly via
  # `send_update(ConnectionsComponent, id: ..., open: provider_name)`.
  def update(%{open: name}, socket), do: {:ok, open_form(socket, name)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:webhooks, Config.webhooks())
     |> assign_new(:show_picker, fn -> true end)
     |> assign_new(:adding, fn -> nil end)
     |> assign_new(:editing_slug, fn -> nil end)
     |> assign_new(:form_label, fn -> nil end)
     |> assign_new(:form_schema, fn -> [] end)
     |> assign_new(:form_values, fn -> %{} end)
     |> assign_new(:form_errors, fn -> %{} end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @adding do %>
        {form_view(assigns)}
      <% else %>
        {list_view(assigns)}
      <% end %>
    </div>
    """
  end

  defp list_view(assigns) do
    assigns = assign(assigns, :active, active_groups(assigns.providers, assigns.webhooks))

    ~H"""
    <div class="space-y-6">
      <%!-- Only providers that actually have a connection get a group. --%>
      <div :for={p <- @active}>
        <div class="mb-2 flex items-center gap-2 font-medium">
          <span>{p.label}</span>
          <span class="rounded bg-zinc-800 px-1.5 py-0.5 font-mono text-xs text-zinc-400">{p.name}</span>
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
              <button phx-click="edit" phx-value-slug={slug} phx-target={@myself} class={btn_ghost()}>{gettext("Edit")}</button>
              <button
                phx-click="delete"
                phx-value-slug={slug}
                phx-target={@myself}
                data-confirm={gettext("Remove connection %{slug}?", slug: slug)}
                class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
              >✕</button>
            </div>
          </div>
          <div class="mt-1 text-sm text-zinc-400">{gettext("Agent:")} {e["agent"] || gettext("(default)")}</div>
          <div class="mt-2 text-sm text-zinc-500">
            {gettext("Webhook URL")}:
            <code class="break-all text-zinc-300">{webhook_url(e["project"], p.name, slug)}</code>
          </div>
          <p class="mt-1 text-xs text-zinc-600">{gettext("Paste this into the provider as its outgoing webhook URL.")}</p>
        </div>
      </div>

      <%!-- One place to start a new connection for any provider (parent may host its own). --%>
      <div :if={@show_picker} class={@active != [] && "border-t border-zinc-800 pt-5"}>
        <div class="mb-2 text-sm font-medium text-zinc-400">{gettext("Add a channel")}</div>
        <div class="flex flex-wrap gap-2">
          <button :for={p <- @providers} phx-click="new" phx-value-name={p.name} phx-target={@myself} class={btn_ghost()}>
            + {p.label}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Providers with at least one connection, in provider order.
  defp active_groups(providers, webhooks),
    do: Enum.filter(providers, fn p -> conns_for(webhooks, p.name) != [] end)

  defp form_view(assigns) do
    ~H"""
    <div class="max-w-2xl">
      <form id={@id <> "-form"} phx-submit="save" phx-change="form_change" phx-target={@myself} class="space-y-4">
        <div class="text-lg font-semibold">
          {(@editing_slug && gettext("Edit %{p} connection", p: @form_label)) ||
            gettext("New %{p} connection", p: @form_label)}
        </div>

        <div :if={@form_errors != %{}} class="rounded-lg border border-red-900/60 bg-red-950/30 px-3.5 py-2.5 text-sm text-red-300">
          {gettext("Please fix the errors below.")}
        </div>

        <.form_section title={gettext("Connection")}>
          <div>
            <label class={lbl()}>{gettext("Slug (URL id)")}</label>
            <input name="slug" value={fval(@form_values, "slug")} class={fld()} placeholder="support" />
            <p :if={@form_errors["slug"]} class="mt-1.5 text-sm text-red-400">{@form_errors["slug"]}</p>
            <p :if={!@form_errors["slug"]} class={hlp()}>{gettext("A unique id used in the webhook URL.")}</p>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class={lbl()}>{gettext("Project")}</label>
              <select name="project" class={fld()}>
                <option value="default" selected={fval(@form_values, "project") in ["", "default"]}>{gettext("Principal")}</option>
                <option :for={c <- @projects} value={c} selected={fval(@form_values, "project") == c}>{c}</option>
              </select>
            </div>
            <div>
              <label class={lbl()}>{gettext("Mode")}</label>
              <select name="mode" class={fld()}>
                <option value="support" selected={fval(@form_values, "mode") != "admin"}>{gettext("Support (customer-facing)")}</option>
                <option value="admin" selected={fval(@form_values, "mode") == "admin"}>{gettext("Admin (yours)")}</option>
              </select>
            </div>
          </div>

          <p class={[hlp(), "-mt-2 flex items-start gap-1.5"]}>
            <span>{(fval(@form_values, "mode") == "admin" && "🛠️") || "🙋"}</span>
            <span>{mode_hint(fval(@form_values, "mode"))}</span>
          </p>

          <div>
            <label class={lbl()}>{gettext("This connection talks to")}</label>
            <select name="agent" class={fld()}>
              <option value="">{gettext("Choose an agent")}</option>
              <option :for={a <- scoped_agent_names(form_project(@form_values))} value={a} selected={fval(@form_values, "agent") == a}>{a}</option>
            </select>
            <p :if={@form_errors["agent"]} class="mt-1.5 text-sm text-red-400">{@form_errors["agent"]}</p>
          </div>
        </.form_section>

        <.form_section title={gettext("Provider credentials")}>
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
        </.form_section>

        <div class="flex gap-2 pt-1">
          <button type="submit" class={btn()}>{gettext("Save connection")}</button>
          <button type="button" phx-click="cancel" phx-target={@myself} class={btn_ghost()}>{gettext("Cancel")}</button>
        </div>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("new", %{"name" => name}, socket), do: {:noreply, open_form(socket, name)}

  def handle_event("edit", %{"slug" => slug}, socket) do
    entry = Config.get_webhook(slug) || %{}

    case find_provider(socket.assigns.providers, entry["provider"]) do
      nil ->
        send(self(), {:flash, :error, gettext("This connection's provider is not installed.")})
        {:noreply, socket}

      p ->
        values = %{
          "slug" => slug,
          "project" => entry["project"] || "default",
          "agent" => entry["agent"] || "",
          "mode" => entry["mode"] || "support",
          "cfg" => entry["config"] || %{}
        }

        {:noreply,
         assign(socket,
           adding: p.name,
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
    send(self(), {:flash, :info, gettext("Removed connection %{s}.", s: slug)})
    {:noreply, assign(socket, webhooks: Config.webhooks())}
  end

  def handle_event("cancel", _p, socket) do
    send(self(), {:channel_form, :closed})
    {:noreply, assign(socket, adding: nil, editing_slug: nil, form_values: %{}, form_errors: %{})}
  end

  # Keep the form live as fields change so the agent list follows the chosen project.
  # Clear the picked agent when the project changes and it no longer belongs there.
  def handle_event("form_change", params, socket) do
    agents = scoped_agent_names(form_project(params))
    params = if params["agent"] in ["" | agents], do: params, else: Map.put(params, "agent", "")
    {:noreply, assign(socket, form_values: params)}
  end

  def handle_event("save", params, socket) do
    name = socket.assigns.adding
    schema = socket.assigns.form_schema
    slug = String.trim(params["slug"] || "")
    agent = blank(params["agent"])
    editing = socket.assigns.editing_slug

    errors = save_errors(slug, agent, editing)

    if errors == %{} do
      persist_connection(name, schema, slug, agent, editing, params)

      {:noreply,
       assign(socket,
         adding: nil,
         editing_slug: nil,
         form_values: %{},
         form_errors: %{},
         webhooks: Config.webhooks()
       )}
    else
      send(self(), {:flash, :error, gettext("Please fix the errors below.")})
      {:noreply, assign(socket, form_values: params, form_errors: errors)}
    end
  end

  defp save_errors(slug, agent, editing) do
    %{}
    |> maybe_error("slug", slug == "" && gettext("A slug is required."))
    |> maybe_error("slug", slug != "" && slug != editing && Config.webhook_exists?(slug) && gettext("This slug is already in use."))
    |> maybe_error("agent", is_nil(agent) && gettext("Choose an agent."))
  end

  defp persist_connection(name, schema, slug, agent, editing, params) do
    mode = (params["mode"] == "admin" && "admin") || "support"
    support? = mode == "support"

    entry =
      reject_nil(%{
        "provider" => name,
        "project" => project_value(params["project"]),
        "agent" => agent,
        "mode" => mode,
        # A support channel is customer-facing: history is ephemeral and it never
        # trains memory; an admin channel keeps history and enables slash commands.
        "commands" => mode == "admin",
        "trainers" => if(support?, do: [], else: nil),
        "ephemeral" => support?,
        "config" => build_config(schema, params["cfg"] || %{})
      })

    if editing && editing != slug, do: Config.delete_webhook(editing)
    Config.put_webhook(slug, entry)
    send(self(), {:flash, :info, gettext("Saved connection %{s}.", s: slug)})
    send(self(), {:channel_form, :closed})
  end

  # ---- helpers -----------------------------------------------------------------------

  defp mode_hint("admin"),
    do: gettext("Admin: a channel you operate. History is kept, slash commands like /new work, and conversations can become memory.")

  defp mode_hint(_),
    do:
      gettext(
        "Support: a customer-facing channel. Each chat is isolated (nothing is remembered between them) and never becomes memory; slash commands are treated as plain text."
      )

  defp open_form(socket, name) do
    case find_provider(socket.assigns.providers, name) do
      nil ->
        socket

      p ->
        default_project =
          if socket.assigns.scope in [nil, "all", "default"], do: "default", else: socket.assigns.scope

        assign(socket,
          adding: name,
          editing_slug: nil,
          form_label: p.label,
          form_schema: p.schema,
          form_values: %{"project" => default_project, "mode" => "support"},
          form_errors: %{}
        )
    end
  end

  defp find_provider(providers, name), do: Enum.find(providers, &(&1.name == name))

  defp conns_for(webhooks, name) do
    webhooks
    |> Enum.filter(fn {_slug, e} -> e["provider"] == name end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp project_value(c) when c in [nil, "", "default"], do: nil
  defp project_value(c), do: c

  # The project selected in the form drives which agents are offered ("default" == the default project).
  defp form_project(values) do
    case Map.get(values, "project") do
      c when c in [nil, ""] -> "default"
      c -> c
    end
  end

  defp build_config(schema, cfg) do
    Enum.reduce(schema, %{}, fn f, acc ->
      case blank(Map.get(cfg, f["key"])) do
        nil -> acc
        v -> Map.put(acc, f["key"], v)
      end
    end)
  end

  defp maybe_error(errors, _field, false), do: errors
  defp maybe_error(errors, field, msg) when is_binary(msg), do: Map.put_new(errors, field, msg)

  defp fval(values, key), do: to_string(Map.get(values, key, ""))
  defp cfgval(values, key), do: to_string(get_in(values, ["cfg", key]) || "")

  defp webhook_url(project, provider, slug),
    do: "#{webhook_host()}/webhooks/#{project || "root"}/#{provider}/#{slug}"

  defp webhook_host, do: System.get_env("PEPE_PUBLIC_URL") || "https://YOUR_HOST"
end
