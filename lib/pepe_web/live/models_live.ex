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
      <p class="col-span-2 text-xs text-zinc-500">
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
            gettext("auto price · in %{in} · out %{out}",
              in: money(i, currency),
              out: money(o, currency)
            )

          nil ->
            gettext("no price - set one to bill for this model")
        end

      {i, o} ->
        gettext("price · in %{in} · out %{out}",
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
  defp blank_model,
    do: %{
      edit: false,
      provider: nil,
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
          desc={gettext("The AI providers your agents run on - any OpenAI-compatible endpoint (OpenAI, OpenRouter, a local model...). Pick a provider and we fill in the rest.")}
        >
          <button phx-click="model_new" class={btn()}>{gettext("+ New connection")}</button>
        </.view_header>
        <div class="flex-1 space-y-3 overflow-y-auto p-6">
          <div :for={m <- scoped_models(@models, @scope)} class={card()}>
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0">
                <span class="font-medium">{m.name}</span>
                <span :if={m.name == @default_model} class="ml-2 rounded bg-green-700 px-1.5 text-xs">{gettext("default")}</span>
              </div>
              <div class="flex shrink-0 gap-1 text-xs">
                <button phx-click="model_edit" phx-value-name={m.name} class={btn_ghost()}>{gettext("Edit")}</button>
                <button :if={m.name != @default_model} phx-click="model_default" phx-value-name={m.name} class={btn_ghost()}>{gettext("Set default")}</button>
                <button phx-click="model_delete" phx-value-name={m.name} data-confirm={gettext("Delete model %{name}?", name: m.name)} class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>✕</button>
              </div>
            </div>
            <div class="mt-1 text-xs text-zinc-400">{m.model} · {m.base_url}</div>
            <div class="mt-0.5 text-xs text-zinc-500">{price_line(m, @currency)}</div>
          </div>

          <%!-- Editing an existing connection: fields shown directly (no provider picker). --%>
          <form :if={@edit_model && @edit_model.edit} phx-submit="model_save" class="space-y-4 rounded-xl border border-orange-900/60 bg-orange-950/10 p-5">
            <div class="text-sm font-medium">{gettext("Edit %{name}", name: @edit_model.name)}</div>
            <input type="hidden" name="name" value={@edit_model.name} />
            <div>
              <label class={lbl()}>{gettext("Name")}</label>
              <input value={@edit_model.name} readonly class={[fld(), "opacity-60"]} />
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
            <label class="flex items-center gap-2 border-t border-zinc-800/60 pt-3 text-xs text-zinc-300">
              <input type="checkbox" name="require_redaction" checked={@edit_model[:require_redaction]} />
              {gettext("Require redaction - refuse to send raw PII to this provider (the agent must run a redaction hook)")}
            </label>
            <div class="flex gap-2 pt-1">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="model_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>

          <%!-- Creating a new connection: provider-driven. --%>
          <form :if={@edit_model && !@edit_model.edit} phx-submit="model_save" class="space-y-4 rounded-xl border border-orange-900/60 bg-orange-950/10 p-5">
            <div class="text-sm font-medium">{gettext("+ New model connection")}</div>

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
                  <input name="name" value={@edit_model.provider} class={fld()} />
                </div>

                <input :if={@edit_model.base_url} type="hidden" name="base_url" value={@edit_model.base_url} />
                <div :if={!@edit_model.base_url}>
                  <label class={lbl()}>{gettext("Base URL")}</label>
                  <input name="base_url" placeholder="https://.../v1" class={fld()} />
                </div>

                <div>
                  <label class={lbl()}>{gettext("Model")}</label>
                  <div :if={@edit_model.models == :loading} class="text-xs text-zinc-500">{gettext("loading models...")}</div>
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
        base_url: base,
        env: env,
        api_key: if(env, do: "${#{env}}", else: nil),
        models: :loading
    }

    spawn_model_fetch(key, base, env && System.get_env(env))
    {:noreply, assign(socket, edit_model: state)}
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
    name = params["name"] |> to_string() |> String.trim() |> scope_name(socket.assigns.scope)

    if name == "" or blank(params["base_url"]) == nil or blank(params["model"]) == nil do
      {:noreply, put_flash(socket, :error, gettext("Name, base URL and model id are required."))}
    else
      # Merge onto any existing connection so an edit keeps fallbacks, headers, etc.
      existing = Config.get_model(name) || %Pepe.Config.Model{name: name}

      Config.put_model(%{
        existing
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
       |> put_flash(:info, gettext("Model %{name} saved.", name: name))}
    end
  end

  def handle_event("model_delete", %{"name" => name}, socket) do
    Config.delete_model(name)

    {:noreply,
     assign(socket, models: Config.models(), default_model: Config.default_model_name())}
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
