defmodule PepeWeb.AiFill do
  @moduledoc """
  A reusable "✦ let AI fill this field" affordance for dashboard forms.

  A small star button next to an input opens a popup where the user describes what they
  want in plain words; a model turns it into the field's value (a cron expression, a
  regex, ...) and the parent drops it into the field. The per-kind context prompt lives
  here (in the generators this dispatches to), so callers only pass a `field` name and a
  `kind`; they never write the prompt.

  The star (`ai_star/1`) sits inside the form next to the input; the popup (`ai_popup/1`)
  is a modal rendered ONCE per page **outside** the form (a form nested in a form is
  invalid HTML and breaks LiveView). Wiring in a LiveView:

    * seed `ai: AiFill.init()` in `mount`;
    * render `<.ai_star field="cron[schedule_custom]" kind="cron" ai={@ai} />` by the input,
      and one `<.ai_popup ai={@ai} models={...} default_model={...} />` outside the form;
    * delegate `ai_toggle` to `AiFill.toggle/3` and `ai_generate` to `start_async` +
      `AiFill.generate/3`, then apply the result with `AiFill.put/3` (or your own merge);
    * read the produced value with `AiFill.value(@ai, field, default)`.
  """

  use Phoenix.Component
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI, only: [fld: 0, btn: 0, hlp: 0]

  # --- parent-embedded state --------------------------------------------------------

  @doc "Initial state for the parent's `ai` assign."
  def init, do: %{open: nil, kind: nil, placeholder: "", busy: false, values: %{}}

  @doc "The AI-produced value for `field`, or `default` if none yet."
  def value(%{values: values}, field, default \\ nil), do: Map.get(values, field, default)

  @doc "Open the popup for `field` (kind + placeholder in tow), or close it if already open."
  def toggle(ai, field, kind, placeholder \\ "") do
    if ai.open == field,
      do: %{ai | open: nil},
      else: %{ai | open: field, kind: kind, placeholder: placeholder}
  end

  @doc "Mark the popup busy (a generation is running)."
  def busy(ai), do: %{ai | busy: true}

  @doc "Record a produced value and close the popup."
  def put(ai, field, value),
    do: %{ai | values: Map.put(ai.values, field, value), busy: false, open: nil}

  @doc "Clear the busy flag (a generation failed) without closing."
  def idle(ai), do: %{ai | busy: false}

  # --- generation dispatch (the prompts live in the generators) ---------------------

  @doc "Turn the user's `description` into a field value for `kind`, using `model`."
  @spec generate(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate("cron", description, model), do: Pepe.Cron.Generate.from_text(description, model)

  def generate("pii_pattern", description, model) do
    case Pepe.Hooks.Generator.pattern(description, model) do
      {:ok, m} -> {:ok, "#{m["name"]}|#{m["pattern"]}|#{m["replace"]}"}
      other -> other
    end
  end

  def generate(_kind, _description, _model), do: {:error, :unknown_kind}

  # --- UI ---------------------------------------------------------------------------

  attr :field, :string, required: true
  attr :kind, :string, required: true
  attr :ai, :map, required: true
  attr :placeholder, :string, default: ""

  @doc "The ✦ button that opens the popup. Sits inside the form, next to the input."
  def ai_star(assigns) do
    ~H"""
    <button type="button" phx-click="ai_toggle" phx-value-field={@field} phx-value-kind={@kind}
      phx-value-placeholder={@placeholder}
      title={gettext("Describe it and let AI fill this field")}
      class={[
        "flex h-[42px] w-11 shrink-0 items-center justify-center rounded-lg border text-lg transition",
        (@ai.open == @field && "border-orange-500 text-orange-300") ||
          "border-zinc-800 text-orange-400 hover:border-zinc-700 hover:text-orange-300"
      ]}>✦</button>
    """
  end

  attr :ai, :map, required: true
  attr :models, :list, default: []
  attr :default_model, :string, default: nil

  @doc "The generation popup, a modal. Render ONCE per page, OUTSIDE any form."
  def ai_popup(assigns) do
    ~H"""
    <div :if={@ai.open} class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      phx-click="ai_toggle" phx-value-field={@ai.open} phx-value-kind={@ai.kind}>
      <div class="w-full max-w-sm rounded-xl border border-orange-500/40 bg-zinc-900 p-4 shadow-2xl"
        onclick="event.stopPropagation()">
        <div class="mb-2 text-[15px] font-medium text-orange-300">✦ {gettext("Fill with AI")}</div>
        <form phx-submit="ai_generate" class="space-y-2">
          <input type="hidden" name="field" value={@ai.open} />
          <input type="hidden" name="kind" value={@ai.kind} />
          <input name="desc" autocomplete="off" autofocus placeholder={@ai.placeholder} class={fld()} />
          <div class="flex gap-2">
            <select name="model" class={fld()} title={gettext("Model used to generate")}>
              <option :for={m <- @models} value={m} selected={m == @default_model}>{m}</option>
            </select>
            <button type="submit" disabled={@ai.busy or @models == []} class={[btn(), "shrink-0"]}>
              {if @ai.busy, do: gettext("Working..."), else: gettext("Generate")}
            </button>
          </div>
        </form>
        <p :if={@models == []} class="mt-1 text-sm text-red-400">{gettext("Add a model first.")}</p>
        <p :if={@models != []} class={hlp()}>{gettext("Describe what you want in plain words; AI writes it.")}</p>
      </div>
    </div>
    """
  end
end
