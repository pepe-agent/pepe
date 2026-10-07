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
  import PepeWeb.TrainersPicker, only: [rename_form: 1, trainers_picker: 1]

  alias Pepe.Config
  alias Pepe.Labels
  alias PepeWeb.TrainersPicker

  @impl true
  # A parent LiveView can open a provider's form directly via
  # `send_update(ConnectionsComponent, id: ..., open: provider_name)`.
  def update(%{open: name}, socket), do: {:ok, open_form(socket, name)}

  # ...and close it again, so a parent that renders its own "Back" button in the page header
  # can dismiss the form without duplicating the reset.
  def update(%{close: true}, socket),
    do: {:ok, assign(socket, adding: nil, editing_slug: nil, form_values: %{}, form_errors: %{})}

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
     |> assign_new(:form_errors, fn -> %{} end)
     |> assign_new(:form_people, fn -> [] end)
     |> assign_new(:renaming, fn -> nil end)
     |> assign_new(:renaming_person, fn -> nil end)}
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
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <.named :if={@renaming != slug} text={Labels.connection(slug, e).text} id={slug} class="font-medium" />
              <button
                :if={@renaming != slug}
                type="button"
                phx-click="rename"
                phx-value-slug={slug}
                phx-target={@myself}
                title={gettext("Rename")}
                class="text-zinc-600 transition hover:text-zinc-200"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
              <%!-- Display only: the slug stays the identity (it is in the webhook URL and every key). --%>
              <form :if={@renaming == slug} phx-submit="save_label" phx-target={@myself} class="flex flex-wrap items-center gap-1">
                <input type="hidden" name="slug" value={slug} />
                <input name="label" value={e["label"] || ""} maxlength="60" placeholder={slug} class={[fld_sm(), "h-[36px] w-56 py-1 text-[14px]"]} />
                <button type="submit" class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>{gettext("Save")}</button>
                <button type="button" phx-click="clear_label" phx-value-slug={slug} phx-target={@myself} class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>
                  {gettext("Clear")}
                </button>
              </form>
              <span class={tag((e["mode"] == "admin" && :warn) || :muted)}>
                {mode_badge(e["mode"])}
              </span>
            </div>
            <div class="flex shrink-0 flex-wrap gap-1 text-sm">
              <button phx-click="edit" phx-value-slug={slug} phx-target={@myself} class={btn_ghost()}>{gettext("Edit")}</button>
              <button
                phx-click="delete"
                phx-value-slug={slug}
                phx-target={@myself}
                data-confirm={gettext("Remove connection %{slug}?", slug: Labels.connection(slug, e).text)}
                class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
              >✕</button>
            </div>
          </div>
          <.meta_list class="mt-4">
            <:item label={gettext("Default agent:")}>
              {e["agent"] || gettext("(default)")}
              <span class="text-zinc-500">{gettext("answers the channels that have no agent of their own")}</span>
            </:item>
            <:item :if={mention_gated?(p.name)} label={gettext("Mention:")}>{mention_default_label(e["mention_optional"] == true)}</:item>
            <:item label={gettext("Webhook URL")} mono>{webhook_url(e["project"], p.name, slug)}</:item>
          </.meta_list>
          <p class="mt-2 text-xs text-zinc-600">{gettext("Paste this into the provider as the address it sends messages to.")}</p>
          <%!-- The channels this connection has heard from, each with its own settings. --%>
          <.live_component
            module={PepeWeb.SeenChannelsComponent}
            id={"seen-" <> slug}
            connection={slug}
            provider={p.name}
            agent={e["agent"]}
            trainers={e["trainers"]}
            mention_optional={e["mention_optional"] == true}
            mention_gated={mention_gated?(p.name)}
            agents={scoped_agent_names(e["project"] || "default")}
            controls={:webhook}
          />
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
    <div class="max-w-3xl">
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
            <p :if={!@form_errors["slug"]} class={hlp()}>{gettext("A short unique name that becomes part of the webhook URL.")}</p>
          </div>

          <div>
            <label class={lbl()}>{gettext("Label")} <span class="text-zinc-600">{gettext("(optional)")}</span></label>
            <input name="label" value={fval(@form_values, "label")} maxlength="60" class={fld()} placeholder={gettext("Support team Slack")} />
            <p class={hlp()}>{gettext("How this connection is shown in the dashboard. The slug above stays the id.")}</p>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
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
                <option value="support" selected={fval(@form_values, "mode") != "admin"}>{gettext("Support (for customers)")}</option>
                <option value="admin" selected={fval(@form_values, "mode") == "admin"}>{gettext("Admin (yours)")}</option>
              </select>
            </div>
          </div>

          <p class={[hlp(), "-mt-2 flex items-start gap-1.5"]}>
            <.icon name={(fval(@form_values, "mode") == "admin" && "hero-wrench-screwdriver") || "hero-user"} class="mt-0.5 size-4 shrink-0 text-zinc-500" />
            <span>{mode_hint(fval(@form_values, "mode"))}</span>
          </p>

          <div>
            <label class={lbl()}>{gettext("Default agent")}</label>
            <select name="agent" class={fld()}>
              <option value="">{gettext("Choose an agent")}</option>
              <option :for={a <- scoped_agent_names(form_project(@form_values))} value={a} selected={fval(@form_values, "agent") == a}>{a}</option>
            </select>
            <p :if={@form_errors["agent"]} class="mt-1.5 text-sm text-red-400">{@form_errors["agent"]}</p>
            <p :if={!@form_errors["agent"]} class={hlp()}>{gettext("Answers the channels of this connection that have no agent of their own.")}</p>
          </div>

          <div>
            <label class={lbl()}>{gettext("Who can train this connection")}</label>
            <.trainers_picker
              id={@id <> "-trainers"}
              field="trainers"
              value={@form_values["trainers"]}
              people={@form_people}
              inherit_label={gettext("Default: everyone in an Admin connection, no one in a Support one")}
              rename_form={@editing_slug && @id <> "-rename-person"}
              renaming={@renaming_person}
              target={@myself}
            />
            <p class={hlp()}>
              {gettext(
                "Pick from the people who have written on any channel of this connection. A channel can have its own list, in its row below or in the chat with /trainers; that one wins for that channel."
              )}
            </p>
          </div>

          <div>
            <label class={lbl()}>{gettext("Who may message this connection")}</label>
            <.trainers_picker
              id={@id <> "-allowed"}
              field="allowed"
              value={@form_values["allowed"]}
              people={@form_people}
              inherit_label={gettext("Anyone")}
              modes={["default", "list"]}
              rename_form={@editing_slug && @id <> "-rename-person"}
              renaming={@renaming_person}
              target={@myself}
            />
            <p class={hlp()}>{gettext("A message from anyone not on the list is ignored. Pick from the people who have written here, or add an id.")}</p>
          </div>

          <div :if={mention_gated?(@adding)}>
            <label class={lbl()}>{gettext("Answer without being mentioned")}</label>
            <select name="mention_optional" class={fld()}>
              <option value="false" selected={fval(@form_values, "mention_optional") != "true"}>{mention_default_label(false)}</option>
              <option value="true" selected={fval(@form_values, "mention_optional") == "true"}>{mention_default_label(true)}</option>
            </select>
            <p class={hlp()}>
              {gettext(
                "The default for every channel of this connection. A channel can have its own setting, from the chat with /mention off always or /mention on always, or in its row below; that one wins for that channel. A direct message always answers."
              )}
            </p>
          </div>
        </.form_section>

        <.form_section title={gettext("Provider access details")}>
          <div :for={f <- @form_schema}>
            <label class={lbl()}>{f["label"]}</label>
            <%!-- The blank option matters: without it the first value is shown and saved for a field
                 nobody ever touched, which for require_mention silently flips the provider's own
                 default. Blank round-trips to "unset" because build_config/2 drops empty values. --%>
            <select :if={f["type"] == "select"} name={"cfg[" <> f["key"] <> "]"} class={fld()}>
              <option value="" selected={cfgval(@form_values, f["key"]) == ""}>{gettext("Not set (use provider's default)")}</option>
              <option :for={o <- f["options"] || []} value={o} selected={cfgval(@form_values, f["key"]) == o}>
                {option_label(f, o)}
              </option>
            </select>
            <input
              :if={f["type"] != "select"}
              name={"cfg[" <> f["key"] <> "]"}
              value={cfgval(@form_values, f["key"])}
              class={[fld(), f["type"] == "secret" && "font-mono"]}
            />
            <p :if={f["hint"]} class={hlp()}>{f["hint"]}</p>
            <p :if={f["type"] == "secret"} class={hlp()}>
              {gettext("Write it as ${ENV_VAR} to keep the secret out of the settings file.")}
            </p>
          </div>
        </.form_section>

        <div class="flex gap-2 pt-1">
          <button type="submit" class={btn()}>{gettext("Save connection")}</button>
          <button type="button" phx-click="cancel" phx-target={@myself} class={btn_ghost()}>{gettext("Cancel")}</button>
        </div>
      </form>
      <%!-- Outside the connection form on purpose: a person's inline rename submits here. --%>
      <.rename_form :if={@editing_slug} id={@id <> "-rename-person"} target={@myself} />
    </div>
    """
  end

  @impl true
  def handle_event("new", %{"name" => name}, socket), do: {:noreply, open_form(socket, name)}

  def handle_event("edit", %{"slug" => slug}, socket) do
    entry = Config.get_webhook(slug) || %{}

    case find_provider(socket.assigns.providers, entry["provider"]) do
      nil ->
        send(self(), {:flash, :error, gettext("The provider for this connection is not installed.")})
        {:noreply, socket}

      p ->
        values = %{
          "slug" => slug,
          "label" => entry["label"] || "",
          "allowed" => TrainersPicker.form_value(allowed_value(entry["allowed_numbers"])),
          "project" => entry["project"] || "default",
          "agent" => entry["agent"] || "",
          "mode" => entry["mode"] || "support",
          "trainers" => TrainersPicker.form_value(entry["trainers"]),
          "mention_optional" => to_string(entry["mention_optional"] == true),
          "cfg" => entry["config"] || %{}
        }

        {:noreply,
         assign(socket,
           form_people: TrainersPicker.people(slug),
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
    text = Labels.connection(slug).text
    Config.delete_webhook(slug)
    Pepe.SeenChannels.delete_connection(slug)
    Pepe.SeenPeople.delete_connection(slug)
    send(self(), {:flash, :info, gettext("Connection %{s} removed.", s: text)})
    {:noreply, assign(socket, webhooks: Config.webhooks())}
  end

  def handle_event("rename", %{"slug" => slug}, socket), do: {:noreply, assign(socket, renaming: slug)}

  def handle_event("save_label", %{"slug" => slug, "label" => label}, socket) do
    {:noreply, socket |> put_connection_label(slug, label) |> assign(renaming: nil)}
  end

  def handle_event("clear_label", %{"slug" => slug}, socket) do
    {:noreply, socket |> put_connection_label(slug, nil) |> assign(renaming: nil)}
  end

  # The people's inline rename inside the form's pickers (see PepeWeb.TrainersPicker).
  def handle_event(event, params, socket) when event in ["rename_person", "save_person_label", "clear_person_label"] do
    socket = TrainersPicker.person_event(event, params, socket, socket.assigns.editing_slug)
    {:noreply, assign(socket, form_people: TrainersPicker.people(socket.assigns.editing_slug))}
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
    |> maybe_error("slug", slug == "" && gettext("Enter a short name for the URL."))
    |> maybe_error("slug", slug != "" && slug != editing && Config.webhook_exists?(slug) && gettext("This short name is already in use."))
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
        "label" => Labels.clean(params["label"]),
        "trainers" => TrainersPicker.to_list(params["trainers"]) || if(support?, do: [], else: nil),
        # An empty list means anyone, which is what absent means too, so it is not stored.
        "allowed_numbers" => allowed_value(TrainersPicker.to_list(params["allowed"])),
        # Stored only when set: absent is "a mention is required", the default since always.
        "mention_optional" => if(params["mention_optional"] == "true", do: true),
        "ephemeral" => support?,
        "config" => build_config(schema, params["cfg"] || %{})
      })

    if editing && editing != slug, do: Config.delete_webhook(editing)
    Config.put_webhook(slug, entry)
    send(self(), {:flash, :info, gettext("Saved connection %{s}.", s: Labels.connection(slug, entry).text)})
    send(self(), {:channel_form, :closed})
  end

  # ---- helpers -----------------------------------------------------------------------

  defp put_connection_label(socket, slug, label) do
    case Config.get_webhook(slug) do
      nil -> socket
      entry -> Config.put_webhook(slug, put_or_delete(entry, "label", Labels.clean(label)))
    end

    assign(socket, webhooks: Config.webhooks())
  end

  # `allowed_numbers` absent or empty both mean anyone; the picker shows that as its default.
  defp allowed_value(list) when is_list(list) and list != [], do: list
  defp allowed_value(_anyone), do: nil

  # The stored value is "support"/"admin"; the badge shows the translated word, never the raw one.
  defp mode_badge("admin"), do: gettext("Admin")
  defp mode_badge(_), do: gettext("Support")

  # The connection's default for every channel; a channel's own setting is in its row.
  defp mention_default_label(true), do: gettext("Yes, in every channel")
  defp mention_default_label(false), do: gettext("No, a mention is required")

  # Only a provider that gates on mentions at all (addressed?/2: Slack, Discord, Teams, Google
  # Chat) has anything to set; WhatsApp answers every message, so the field would be noise.
  defp mention_gated?(name) when is_binary(name) do
    case Pepe.Webhooks.provider(name) do
      nil -> false
      mod -> Code.ensure_loaded?(mod) and function_exported?(mod, :addressed?, 2)
    end
  end

  defp mention_gated?(_name), do: false

  # A schema's option list is raw config values. When those values are just a boolean written as
  # strings, the operator should read Yes/No, not `true`/`false`; anything else shows as-is,
  # since only the provider knows what its own values mean.
  # A provider that wants its own words shown instead of the raw value gives `option_labels`
  # (value => already translated text).
  defp option_label(field, o) do
    cond do
      is_map(field["option_labels"]) and is_binary(field["option_labels"][o]) -> field["option_labels"][o]
      boolean_options?(field["options"]) -> boolean_label(o)
      true -> o
    end
  end

  defp boolean_options?(options) when is_list(options),
    do: options |> Enum.map(&String.downcase(to_string(&1))) |> Enum.sort() == ["false", "true"]

  defp boolean_options?(_), do: false

  defp boolean_label(o) do
    case String.downcase(to_string(o)) do
      "true" -> gettext("Yes")
      _ -> gettext("No")
    end
  end

  defp mode_hint("admin"),
    do:
      gettext(
        "Admin: a channel only you and your team use. Chats are remembered, commands like /new work, and what you talk about can be saved to memory."
      )

  defp mode_hint(_),
    do:
      gettext(
        "Support: a channel for customers. Each chat starts from scratch, nothing is remembered between chats or saved to memory, and commands like /new are read as plain text."
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
          form_errors: %{},
          # Nobody has written to a connection that does not exist yet.
          form_people: []
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

  defp webhook_url(project, provider, slug), do: Pepe.Webhooks.callback_url(project, provider, slug)
end
