defmodule PepeWeb.ModelsLive do
  @moduledoc "Model connections section: the OpenAI-compatible providers agents run on."
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Pricing

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Models",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       currency: Config.currency(),
       models: Config.models(),
       default_model: Config.default_model_name(),
       edit_model: nil
     )}
  end

  # Per-model billing prices: manual override with the auto/known price as placeholder.
  attr :edit_model, :map, required: true
  attr :currency, :string, required: true

  defp price_fields(assigns) do
    assigns = assign(assigns, :suggest, Pricing.lookup(assigns.edit_model[:model_id]))

    ~H"""
    <div class="grid grid-cols-2 gap-3 border-t border-zinc-800/60 pt-3">
      <div>
        <label class={lbl()}>{gettext("Input price")} <span class="text-zinc-600">{gettext("/ 1M tok")}</span></label>
        <input name="input_price" value={@edit_model[:input_price]} placeholder={suggest_ph(@suggest, 0)} inputmode="decimal" class={fld()} />
      </div>
      <div>
        <label class={lbl()}>{gettext("Output price")} <span class="text-zinc-600">{gettext("/ 1M tok")}</span></label>
        <input name="output_price" value={@edit_model[:output_price]} placeholder={suggest_ph(@suggest, 1)} inputmode="decimal" class={fld()} />
      </div>
      <p class="col-span-2 text-sm text-zinc-500">
        {gettext("Per 1M tokens, in %{currency}. Leave blank to use the known/auto price for this model.", currency: @currency)}
      </p>
    </div>
    """
  end

  defp suggest_ph({i, _o}, 0) when is_number(i), do: num_str(i)
  defp suggest_ph({_i, o}, 1) when is_number(o), do: num_str(o)
  defp suggest_ph(_suggest, _idx), do: ""

  defp num_str(n), do: n |> :erlang.float_to_binary([:compact, {:decimals, 4}])

  # The price line under a model card: manual price, auto price from the book, or a
  # nudge to set one so the model can be billed.
  defp price_line(m, currency) do
    case {m.input_price, m.output_price} do
      {nil, nil} ->
        case Pricing.lookup(m.model) do
          {i, o} ->
            gettext("Auto price · in %{in} · out %{out}",
              in: money(i, currency),
              out: money(o, currency)
            )

          nil ->
            gettext("No price. Set one to bill for this model")
        end

      {i, o} ->
        gettext("Price · in %{in} · out %{out}",
          in: money(i || 0.0, currency),
          out: money(o || 0.0, currency)
        )
    end
  end

  defp parse_price(value) do
    case value |> to_string() |> String.trim() |> String.replace(",", ".") do
      "" ->
        nil

      s ->
        case Float.parse(s) do
          {f, _} when f >= 0 -> f
          _ -> nil
        end
    end
  end

  # A fresh new-connection form state (provider-driven, not editing).
  # A free, human-editable suggestion for a new connection's name: the provider
  # key itself if unused, else "key-2", "key-3", ... so naming a second account
  # on the same provider never silently collides with (and overwrites) the first.
  defp unique_suggestion(key, scope) do
    taken = Config.models() |> Enum.map(& &1.name)

    if scope_name(key, scope) not in taken do
      key
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{key}-#{n}"
        if scope_name(candidate, scope) not in taken, do: candidate
      end)
    end
  end

  defp blank_model,
    do: %{
      edit: false,
      provider: nil,
      name: nil,
      base_url: nil,
      env: nil,
      api_key: nil,
      models: [],
      model_id: nil
    }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="models" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔌"
          title={gettext("Model connections")}
          desc={gettext("The AI providers your agents run on: any OpenAI-compatible endpoint (OpenAI, OpenRouter, a local model...). Pick a provider and we fill in the rest.")}
        >
          <button :if={!@edit_model} phx-click="model_new" class={btn()}>{gettext("+ New connection")}</button>
          <button :if={@edit_model} phx-click="model_cancel" class={btn_ghost()}>&larr; {gettext("Back to models")}</button>
        </.view_header>
        <div class="flex-1 overflow-y-auto p-6">
          <div :if={!@edit_model} class="space-y-3">
          <div :for={m <- scoped_models(@models, @scope)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{m.name}</span>
                <span :if={m.name == @default_model} class="ml-2 rounded bg-green-700 px-1.5 text-sm">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-sm">
                <button phx-click="model_edit" phx-value-name={m.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={m.name != @default_model} phx-click="model_default" phx-value-name={m.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="model_delete" phx-value-name={m.name} data-confirm={gettext("Delete model %{name}?", name: m.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-sm text-zinc-400">{m.model} · {m.base_url}</div>
            <div class="mt-0.5 text-sm text-zinc-500">{price_line(m, @currency)}</div>
          </div>
          </div>

          <div :if={@edit_model} class="max-w-2xl">
          <%!-- Editing an existing connection: fields shown directly (no provider picker). --%>
          <form :if={@edit_model.edit} phx-submit="model_save" class="space-y-4">
            <div class="text-lg font-semibold">{gettext("Edit %{name}", name: @edit_model.original_name)}</div>
            <input type="hidden" name="original_name" value={@edit_model.original_name} />
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input name="name" value={@edit_model.name} phx-change="model_name_change" class={fld()} />
              <p class={hlp()}>{gettext("Renaming updates every agent, cron, hook and default pointing at this connection.")}</p>
            </div>
            <div>
              <label class={lbl()}>{gettext("Base URL")}</label>
              <input name="base_url" value={@edit_model.base_url} class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("Model")}</label>
              <input name="model" value={@edit_model.model_id} class={fld()} />
            </div>
            <div>
              <label class={lbl()}>{gettext("API key")}</label>
              <input name="api_key" value={@edit_model.api_key} class={fld()} />
            </div>
            <.price_fields edit_model={@edit_model} currency={@currency} />
            <label class="flex items-center gap-2 border-t border-zinc-800/60 pt-3 text-sm text-zinc-300">
              <input type="checkbox" name="require_redaction" checked={@edit_model[:require_redaction]} />
              {gettext("Require redaction: refuse to send raw PII to this provider (the agent must run a redaction hook)")}
            </label>
            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="model_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>

          <%!-- Creating a new connection: provider-driven. --%>
          <form :if={!@edit_model.edit} phx-submit="model_save" class="space-y-4">
            <div class="text-lg font-semibold">{gettext("+ New model connection")}</div>

            <div>
              <label class={lbl()}>{gettext("Provider")}</label>
              <select name="provider" phx-change="model_pick_provider" class={fld()}>
                <option value="">{gettext("Choose a provider...")}</option>
                <option :for={{k, label} <- provider_options()} value={k} selected={k == @edit_model.provider}>{label}</option>
              </select>
            </div>

            <div :if={@edit_model.provider}>
              <div class="space-y-3">
                <div>
                  <label class={lbl()}>{gettext("Name")} <span class="text-zinc-600">{gettext("(this connection)")}</span></label>
                  <input name="name" value={@edit_model.name} phx-change="model_name_change" class={fld()} />
                </div>

                <input :if={@edit_model.base_url} type="hidden" name="base_url" value={@edit_model.base_url} />
                <div :if={!@edit_model.base_url}>
                  <label class={lbl()}>{gettext("Base URL")}</label>
                  <input name="base_url" placeholder="https://.../v1" class={fld()} />
                </div>

                <div>
                  <label class={lbl()}>{gettext("Model")}</label>
                  <div :if={@edit_model.models == :loading} class="text-sm text-zinc-500">{gettext("Loading models...")}</div>
                  <select :if={is_list(@edit_model.models) and @edit_model.models != []} name="model" class={fld()}>
                    <option :for={id <- @edit_model.models} value={id}>{id}</option>
                  </select>
                  <input :if={@edit_model.models == []} name="model" placeholder={gettext("model id (e.g. gpt-5)")} class={fld()} />
                </div>

                <div :if={@edit_model.env}>
                  <label class={lbl()}>{gettext("API key")}</label>
                  <input name="api_key" value={@edit_model.api_key} phx-blur="model_key" class={fld()} />
                  <p class={hlp()}>
                    {gettext("Defaults to the %{env} env var (%{status}). Paste a key here to load its models now.",
                      env: @edit_model.env, status: key_status(@edit_model.env))}
                  </p>
                </div>

                <.price_fields edit_model={@edit_model} currency={@currency} />
              </div>
            </div>

            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="model_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("model_new", _p, socket) do
    {:noreply, assign(socket, edit_model: blank_model())}
  end

  def handle_event("model_edit", %{"name" => name}, socket) do
    case Config.get_model(name) do
      nil ->
        {:noreply, socket}

      m ->
        {:noreply,
         assign(socket,
           edit_model: %{
             edit: true,
             provider: nil,
             env: nil,
             models: [],
             name: m.name,
             original_name: m.name,
             base_url: m.base_url,
             model_id: m.model,
             api_key: m.api_key,
             input_price: m.input_price,
             output_price: m.output_price,
             require_redaction: m.require_redaction
           }
         )}
    end
  end

  def handle_event("model_cancel", _p, socket), do: {:noreply, assign(socket, edit_model: nil)}

  def handle_event("model_pick_provider", %{"provider" => ""}, socket) do
    {:noreply, assign(socket, edit_model: blank_model())}
  end

  def handle_event("model_pick_provider", %{"provider" => key}, socket) do
    p = Pepe.Providers.get(key)
    env = p && p[:env]
    base = p && p[:base_url]

    state = %{
      blank_model()
      | provider: key,
        # A starting suggestion, not a permanent binding: the input below is
        # freely editable, so you can name a second connection to the same
        # provider (a different account/key) whatever you like, e.g. "OR-key2".
        name: unique_suggestion(key, socket.assigns.scope),
        base_url: base,
        env: env,
        api_key: if(env, do: "${#{env}}", else: nil),
        models: :loading
    }

    spawn_model_fetch(key, base, env && System.get_env(env))
    {:noreply, assign(socket, edit_model: state)}
  end

  # Keeps edit_model.name in sync with what's actually typed, so a later
  # server-driven re-render (e.g. the async model list arriving) can never
  # silently revert the field back to its initial suggestion.
  def handle_event("model_name_change", %{"name" => name}, socket) do
    {:noreply, assign(socket, edit_model: %{socket.assigns.edit_model | name: name})}
  end

  def handle_event("model_key", %{"value" => raw}, socket) do
    case socket.assigns.edit_model do
      %{provider: p, base_url: base} = m when not is_nil(p) ->
        spawn_model_fetch(p, base, Config.interpolate(raw))
        {:noreply, assign(socket, edit_model: %{m | models: :loading})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("model_save", params, socket) do
    raw_name = params["name"] |> to_string() |> String.trim()
    creating? = !socket.assigns.edit_model.edit

    cond do
      raw_name == "" or blank(params["base_url"]) == nil or blank(params["model"]) == nil ->
        {:noreply, put_flash(socket, :error, gettext("Name, base URL and model id are required."))}

      creating? ->
        save_new_model(socket, raw_name, params)

      true ->
        save_edited_model(socket, raw_name, params)
    end
  end

  def handle_event("model_delete", %{"name" => name}, socket) do
    Config.delete_model(name)

    {:noreply, assign(socket, models: Config.models(), default_model: Config.default_model_name())}
  end

  def handle_event("model_default", %{"name" => name}, socket) do
    Config.set_default_model(name)
    {:noreply, assign(socket, default_model: name)}
  end

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/models")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  # Never overwrite an existing connection on create: auto-suffix instead
  # (openrouter -> openrouter-2 -> ...), same as the CLI, then tell the user
  # what it actually landed on so they can rename it if they want.
  defp save_new_model(socket, raw_name, params) do
    scope = socket.assigns.scope
    final_raw = unique_suggestion(raw_name, scope)
    name = scope_name(final_raw, scope)

    socket =
      if final_raw != raw_name do
        put_flash(
          socket,
          :info,
          gettext("A model connection named %{name} already exists - saved this one as %{final} instead.",
            name: scope_name(raw_name, scope),
            final: name
          )
        )
      else
        socket
      end

    write_model(socket, name, params, gettext("Model %{name} saved.", name: name))
  end

  defp save_edited_model(socket, raw_name, params) do
    scope = socket.assigns.scope
    original = params["original_name"] |> to_string() |> String.trim()
    name = scope_name(raw_name, scope)

    cond do
      name != original and Config.get_model(name) != nil ->
        {:noreply,
         put_flash(socket, :error, gettext("A model connection named %{name} already exists. Choose a different name.", name: name))}

      name != original ->
        case Config.rename_model(original, name) do
          :ok ->
            write_model(socket, name, params, gettext("Model %{old} renamed to %{name} and saved.", old: original, name: name))

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't rename %{old}.", old: original))}
        end

      true ->
        write_model(socket, name, params, gettext("Model %{name} saved.", name: name))
    end
  end

  # Merges onto the existing connection (by then-current name) so a save keeps
  # fallbacks and any other field this form doesn't expose.
  defp write_model(socket, name, params, message) do
    base = Config.get_model(name) || %Pepe.Config.Model{name: name}

    Config.put_model(%{
      base
      | name: name,
        base_url: params["base_url"],
        api_key: blank(params["api_key"]),
        model: params["model"],
        input_price: parse_price(params["input_price"]),
        output_price: parse_price(params["output_price"]),
        require_redaction: params["require_redaction"] == "on" || nil
    })

    {:noreply,
     socket
     |> assign(
       models: Config.models(),
       edit_model: nil,
       default_model: Config.default_model_name()
     )
     |> put_flash(:info, message)}
  end

  @impl true
  def handle_info({:models_loaded, provider, ids}, socket) do
    case socket.assigns.edit_model do
      %{provider: ^provider} = m -> {:noreply, assign(socket, edit_model: %{m | models: ids})}
      _ -> {:noreply, socket}
    end
  end

  # Fetch a provider's model ids off-process so the LiveView never blocks on the call.
  defp spawn_model_fetch(provider, base, resolved_key) do
    parent = self()

    spawn(fn ->
      ids =
        with true <- is_binary(base),
             probe = %Pepe.Config.Model{
               name: "probe",
               base_url: base,
               api_key: resolved_key,
               model: "",
               api: "openai"
             },
             {:ok, list} <- Pepe.LLM.list_models(probe) do
          list
        else
          _ -> []
        end

      send(parent, {:models_loaded, provider, ids})
    end)
  end
end
