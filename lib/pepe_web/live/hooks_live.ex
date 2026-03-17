defmodule PepeWeb.HooksLive do
  @moduledoc """
  Configure the privacy (redaction) hooks. Hooks are turned *on* per agent (Agents
  page); this is where each hook's settings live: recognizers/packs for the regex
  redactor, a model for the LLM redactor, or endpoints for the HTTP / Presidio ones.
  It also carries the "describe what to hide and let a model build it" generator for
  `pii_redact`.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI

  alias Pepe.Config
  alias Pepe.Hooks
  alias Pepe.Hooks.PII.Recognizers

  @icons %{
    "pii_redact" => "🧩",
    "llm_redact" => "🧠",
    "http_redact" => "🔌",
    "presidio" => "🛡️"
  }

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pepe · Privacy",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       editing: nil,
       edit: %{},
       gen_desc: "",
       gen_model: Config.default_model_name(),
       gen_busy: false
     )
     |> load()}
  end

  defp load(socket),
    do: assign(socket, settings: Config.hooks_settings(), agents: Config.agents())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="hooks" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🛡️"
          title={gettext("Privacy hooks")}
          desc={gettext("Redact PII on the message flow before it reaches a model. Configure a hook here, then enable it on an agent (Agents). Empty = no redaction (raw text).")}
        />

        <div class="min-h-0 flex-1 overflow-y-auto p-6">
          <%= if @editing do %>
            {form_panel(assigns)}
          <% else %>
            <p class="mb-4 max-w-4xl text-sm leading-relaxed text-zinc-500">
              <span class="text-zinc-400">{gettext("PII = personally identifiable information")}</span>
              {gettext(": any data that points to a specific person, like name, CPF/CNPJ, email, phone, card, address. These hooks hide it before the text reaches a model, so the provider never sees the real data.")}
            </p>
            <div class="grid max-w-4xl gap-3 sm:grid-cols-2">
              <div :for={name <- Hooks.names()} class={card()}>
                <div class="flex items-start justify-between gap-2">
                  <div class="flex items-center gap-2 font-medium">
                    <span>{meta_icon(name)}</span> <span>{meta_title(name)}</span>
                  </div>
                  <span class={[
                    "rounded-full px-2 py-0.5 text-[11px] font-medium",
                    (configured?(@settings, name) && "bg-orange-600/20 text-orange-300") ||
                      "bg-zinc-800 text-zinc-500"
                  ]}>
                    {(configured?(@settings, name) && gettext("configured")) || gettext("not set")}
                  </span>
                </div>
                <p class="mt-1.5 text-sm leading-relaxed text-zinc-500">{meta_desc(name)}</p>
                <p class="mt-2 text-xs text-zinc-600">{used_by(@agents, name)}</p>
                <div class="mt-3 flex gap-2">
                  <button phx-click="edit" phx-value-name={name} class={btn()}>{gettext("Configure")}</button>
                  <button
                    :if={configured?(@settings, name)}
                    phx-click="clear"
                    phx-value-name={name}
                    data-confirm={gettext("Clear this hook's settings?")}
                    class={btn_ghost()}
                  >{gettext("Clear")}</button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  # ---- per-hook form panel ------------------------------------------------

  defp form_panel(assigns) do
    ~H"""
    <div class="max-w-2xl">
      <button phx-click="cancel" class="mb-3 text-sm text-zinc-500 hover:text-zinc-300">
        &larr; {gettext("Back to hooks")}
      </button>
      <div class="mb-4 flex items-center gap-2">
        <span class="text-lg">{meta_icon(@editing)}</span>
        <div>
          <div class="font-medium">{meta_title(@editing)}</div>
          <div class="text-sm text-zinc-500">{@editing}</div>
        </div>
      </div>

      {generator(assigns)}

      <form phx-submit="save" class="space-y-4">
        {fields(assigns)}
        <div class="flex items-center gap-2 border-t border-zinc-800 pt-4">
          <button type="submit" class={btn()}>{gettext("Save")}</button>
          <button type="button" phx-click="cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
        </div>
      </form>
    </div>
    """
  end

  # The AI generator box, only for the regex redactor.
  defp generator(%{editing: "pii_redact"} = assigns) do
    ~H"""
    <div class="mb-5 rounded-xl border border-orange-600/30 bg-orange-600/5 p-4">
      <div class="mb-1 text-[15px] font-medium text-orange-300">✨ {gettext("Generate with AI")}</div>
      <p class={hlp()}>{gettext("Describe what to hide in plain words; a model builds the recognizers + regex below (validated). Review, then Save.")}</p>
      <form phx-submit="generate" class="mt-2 space-y-2">
        <input
          name="desc"
          value={@gen_desc}
          placeholder={gettext("e.g. hide CPF, email and Brazilian phone numbers")}
          class={fld()}
        />
        <div class="flex gap-2">
          <select name="model" class={fld()} title={gettext("Model used to generate the config")}>
            <option :if={Config.models() == []} value="">{gettext("no models configured")}</option>
            <option :for={m <- Config.models()} value={m.name} selected={m.name == @gen_model}>{m.name}</option>
          </select>
          <button type="submit" disabled={@gen_busy} class={[btn(), "shrink-0", @gen_busy && "opacity-60"]}>
            {(@gen_busy && gettext("Working...")) || gettext("Generate")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp generator(assigns), do: ~H""

  defp fields(%{editing: "pii_redact"} = assigns) do
    ~H"""
    <div>
      <label class={lbl()}>{gettext("Recognizer packs")}</label>
      <div class="flex flex-wrap gap-3">
        <label :for={p <- Map.keys(Recognizers.packs())} class="flex items-center gap-1.5 text-sm text-zinc-300">
          <input type="checkbox" name="packs[]" value={p} checked={p in list(@edit, "packs")} /> {p}
        </label>
      </div>
      <p class={hlp()}>{gettext("Region bundles: intl (email/card/ip), br (cpf/cnpj/cep/phone), us (ssn/phone).")}</p>
    </div>

    <div>
      <label class={lbl()}>{gettext("Individual recognizers")}</label>
      <div class="flex flex-wrap gap-x-3 gap-y-1.5">
        <label :for={r <- Recognizers.builtin_names()} class="flex items-center gap-1.5 text-sm text-zinc-300">
          <input type="checkbox" name="recognizers[]" value={r} checked={r in list(@edit, "recognizers")} /> {r}
        </label>
      </div>
    </div>

    <div>
      <label class={lbl()}>{gettext("Custom patterns")}</label>
      <textarea name="custom" rows="3" spellcheck="false" placeholder="name|pattern|REPLACE" class={fld() <> " font-mono text-sm"}>{custom_text(@edit)}</textarea>
      <p class={hlp()}>{gettext("One per line: name|regex|REPLACE_LABEL. Invalid regex is dropped on save.")}</p>
    </div>

    <label class="flex items-center gap-2 text-[15px] text-zinc-300">
      <input type="checkbox" name="reversible" value="true" checked={bool(@edit, "reversible", true)} />
      {gettext("Reversible (restore the real values on the reply)")}
    </label>
    <.reversible_note />
    """
  end

  defp fields(%{editing: "llm_redact"} = assigns) do
    ~H"""
    <div>
      <label class={lbl()}>{gettext("Model")}</label>
      <select name="model" class={fld()}>
        <option value="">{gettext("pick a configured model")}</option>
        <option :for={m <- Config.models()} value={m.name} selected={@edit["model"] == m.name}>{m.name}</option>
      </select>
      <p class={hlp()}>{gettext("A local/cheap model is ideal: it only rewrites PII into pseudonyms.")}</p>
    </div>

    <label class="flex items-center gap-2 text-[15px] text-zinc-300">
      <input type="checkbox" name="reversible" value="true" checked={bool(@edit, "reversible", true)} />
      {gettext("Reversible (restore the real values on the reply)")}
    </label>
    <.reversible_note />
    """
  end

  defp fields(%{editing: "http_redact"} = assigns) do
    ~H"""
    <.text_field name="url" label={gettext("Endpoint URL")} value={@edit["url"]} hint={gettext("Used for both directions unless you set separate URLs below.")} />
    <.text_field name="inbound_url" label={gettext("Inbound URL (optional)")} value={@edit["inbound_url"]} />
    <.text_field name="outbound_url" label={gettext("Outbound URL (optional)")} value={@edit["outbound_url"]} />
    <div class="grid grid-cols-2 gap-3">
      <.text_field name="basic_user" label={gettext("Basic auth user")} value={get_in(@edit, ["basic_auth", "user"])} />
      <.text_field name="basic_password" label={gettext("Basic auth password")} value={get_in(@edit, ["basic_auth", "password"])} />
    </div>
    <div>
      <label class={lbl()}>{gettext("Extra headers")}</label>
      <textarea name="headers" rows="2" spellcheck="false" placeholder="X-Api-Key: ${MY_KEY}" class={fld() <> " font-mono text-sm"}>{headers_text(@edit)}</textarea>
      <p class={hlp()}>{gettext("One per line: Header-Name: value. Secrets can use ${ENV_VAR}.")}</p>
    </div>
    """
  end

  defp fields(%{editing: "presidio"} = assigns) do
    ~H"""
    <.text_field name="analyzer_url" label={gettext("Analyzer URL")} value={@edit["analyzer_url"]} />
    <.text_field name="anonymizer_url" label={gettext("Anonymizer URL")} value={@edit["anonymizer_url"]} />
    <div class="grid grid-cols-2 gap-3">
      <.text_field name="language" label={gettext("Language")} value={@edit["language"] || "en"} />
      <.text_field name="score_threshold" label={gettext("Score threshold")} value={@edit["score_threshold"]} hint="0.0 - 1.0" />
    </div>
    <.text_field name="entities" label={gettext("Entities (comma-separated, optional)")} value={Enum.join(list(@edit, "entities"), ", ")} />
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :hint, :string, default: nil

  defp text_field(assigns) do
    ~H"""
    <div>
      <label class={lbl()}>{@label}</label>
      <input name={@name} value={@value} class={fld()} />
      <p :if={@hint} class={hlp()}>{@hint}</p>
    </div>
    """
  end

  # A compact before/after that makes the `reversible` option self-explanatory.
  defp reversible_note(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
      <div class="mb-1.5 text-sm font-medium text-zinc-400">{gettext("How reversible works")}</div>
      <div class="space-y-0.5 font-mono text-xs leading-relaxed">
        <div><span class="text-zinc-500">{gettext("you")}: </span><span class="text-zinc-300">meu CPF é 123.456.789-09</span></div>
        <div><span class="text-zinc-500">{gettext("model sees")}: </span><span class="text-orange-300">meu CPF é [CPF_1]</span></div>
        <div><span class="text-zinc-500">{gettext("reply")}: </span><span class="text-zinc-300">boleto do CPF 123.456.789-09 ✓</span></div>
      </div>
      <p class={hlp()}>{gettext("On: the real value is restored in the reply. Off: one-way, the model and you keep the masked version.")}</p>
    </div>
    """
  end

  # ---- events -------------------------------------------------------------

  @impl true
  def handle_event("edit", %{"name" => name}, socket) do
    {:noreply, assign(socket, editing: name, edit: Config.hook_settings(name), gen_desc: "")}
  end

  def handle_event("cancel", _p, socket), do: {:noreply, assign(socket, editing: nil, edit: %{})}

  def handle_event("clear", %{"name" => name}, socket) do
    Config.put_hook_settings(name, %{})

    {:noreply, socket |> load() |> put_flash(:info, gettext("Cleared %{h}.", h: meta_title(name)))}
  end

  def handle_event("save", params, socket) do
    name = socket.assigns.editing
    settings = build_settings(name, params)
    Config.put_hook_settings(name, settings)

    {:noreply,
     socket
     |> assign(editing: nil, edit: %{})
     |> load()
     |> put_flash(:info, gettext("Saved %{h}.", h: meta_title(name)))}
  end

  def handle_event("generate", %{"desc" => desc} = params, socket) do
    case blank(params["model"]) || Config.default_model_name() do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Add a model first to use the generator."))}

      model ->
        {:noreply,
         socket
         |> assign(gen_busy: true, gen_desc: desc, gen_model: model)
         |> start_async(:generate, fn -> Hooks.Generator.generate(desc, model) end)}
    end
  end

  # sidebar scope events (shared shape with the other sections)
  def handle_event("set_scope", %{"scope" => scope}, socket),
    do: {:noreply, push_navigate(socket, to: "/hooks?scope=#{scope}")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", %{"name" => name}, socket) do
    case Config.add_company(String.trim(name)) do
      :ok -> {:noreply, push_navigate(socket, to: "/agents?scope=#{name}")}
      _ -> {:noreply, put_flash(socket, :error, gettext("Invalid or duplicate company name."))}
    end
  end

  @impl true
  def handle_async(:generate, {:ok, {:ok, config, dropped}}, socket) do
    msg =
      if dropped == [],
        do: gettext("Generated a config below. Review and Save."),
        else:
          gettext("Generated (dropped invalid: %{d}) - review and Save.",
            d: Enum.join(dropped, ", ")
          )

    {:noreply,
     socket
     |> assign(edit: Map.merge(socket.assigns.edit, config), gen_busy: false)
     |> put_flash(:info, msg)}
  end

  def handle_async(:generate, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(gen_busy: false)
     |> put_flash(:error, gettext("Generator failed: %{r}", r: inspect(reason)))}
  end

  def handle_async(:generate, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(gen_busy: false)
     |> put_flash(:error, gettext("Generator crashed: %{r}", r: inspect(reason)))}
  end

  # ---- build settings from form params ------------------------------------

  defp build_settings("pii_redact", p) do
    %{}
    |> put_nonempty("packs", p["packs"] || [])
    |> put_nonempty("recognizers", p["recognizers"] || [])
    |> put_nonempty("custom", parse_custom(p["custom"]))
    |> Map.put("reversible", p["reversible"] == "true")
  end

  defp build_settings("llm_redact", p) do
    %{}
    |> put_nonempty("model", p["model"])
    |> Map.put("reversible", p["reversible"] == "true")
  end

  defp build_settings("http_redact", p) do
    %{}
    |> put_nonempty("url", p["url"])
    |> put_nonempty("inbound_url", p["inbound_url"])
    |> put_nonempty("outbound_url", p["outbound_url"])
    |> put_basic_auth(p)
    |> put_nonempty("headers", parse_headers(p["headers"]))
  end

  defp build_settings("presidio", p) do
    %{}
    |> put_nonempty("analyzer_url", p["analyzer_url"])
    |> put_nonempty("anonymizer_url", p["anonymizer_url"])
    |> put_nonempty("language", p["language"])
    |> put_nonempty("entities", split_csv(p["entities"]))
    |> put_float("score_threshold", p["score_threshold"])
  end

  defp put_basic_auth(map, p) do
    user = String.trim(p["basic_user"] || "")
    pass = String.trim(p["basic_password"] || "")

    if user == "" and pass == "",
      do: map,
      else: Map.put(map, "basic_auth", %{"user" => user, "password" => pass})
  end

  defp parse_custom(nil), do: []

  defp parse_custom(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "|", parts: 3))
    |> Enum.flat_map(fn
      [name, pattern | rest] ->
        name = String.trim(name)
        pattern = String.trim(pattern)
        replace = rest |> List.first("") |> String.trim()

        if name != "" and Recognizers.valid_pattern?(pattern) do
          entry = %{"name" => name, "pattern" => pattern}
          [if(replace != "", do: Map.put(entry, "replace", replace), else: entry)]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp parse_headers(nil), do: %{}

  defp parse_headers(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ":", parts: 2))
    |> Enum.flat_map(fn
      [k, v] -> [{String.trim(k), String.trim(v)}]
      _ -> []
    end)
    |> Map.new()
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(s), do: s

  defp split_csv(nil), do: []

  defp split_csv(s),
    do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp put_nonempty(map, _key, ""), do: map
  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, _key, m) when m == %{}, do: map
  defp put_nonempty(map, _key, nil), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp put_float(map, key, s) do
    case s && Float.parse(String.trim(s)) do
      {f, _} -> Map.put(map, key, f)
      _ -> map
    end
  end

  # ---- view helpers -------------------------------------------------------

  defp configured?(settings, name), do: Map.get(settings, name, %{}) not in [nil, %{}]

  defp used_by(agents, name) do
    names = agents |> Enum.filter(&(name in (&1.hooks || []))) |> Enum.map(& &1.name)

    case names do
      [] -> gettext("not used by any agent yet")
      list -> gettext("used by: %{a}", a: Enum.join(list, ", "))
    end
  end

  defp list(edit, key) do
    case Map.get(edit, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  defp bool(edit, key, default) do
    case Map.get(edit, key) do
      b when is_boolean(b) -> b
      _ -> default
    end
  end

  defp custom_text(edit) do
    edit
    |> list("custom")
    |> Enum.map_join("\n", fn c ->
      [c["name"], c["pattern"], c["replace"]] |> Enum.reject(&is_nil/1) |> Enum.join("|")
    end)
  end

  defp headers_text(edit) do
    case Map.get(edit, "headers") do
      m when is_map(m) -> Enum.map_join(m, "\n", fn {k, v} -> "#{k}: #{v}" end)
      _ -> ""
    end
  end

  defp meta_icon(name), do: Map.get(@icons, name)

  # Titles/descriptions go through gettext (literals, so they extract) rather than the
  # compile-time @meta strings.
  defp meta_title("pii_redact"), do: gettext("Regex redaction")
  defp meta_title("llm_redact"), do: gettext("Model redaction")
  defp meta_title("http_redact"), do: gettext("HTTP redaction")
  defp meta_title("presidio"), do: gettext("Presidio")

  defp meta_desc("pii_redact"),
    do: gettext("Deterministic structured PII (CPF, CNPJ, email, cards, phones) via named recognizers and your own regex.")

  defp meta_desc("llm_redact"),
    do: gettext("A local model swaps names and free text for realistic, reversible pseudonyms.")

  defp meta_desc("http_redact"),
    do: gettext("Send text to your own redaction service (one endpoint, or separate inbound/outbound).")

  defp meta_desc("presidio"), do: gettext("Microsoft Presidio analyzer + anonymizer over HTTP.")
end
