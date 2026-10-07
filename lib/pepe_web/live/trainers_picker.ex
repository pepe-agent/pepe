defmodule PepeWeb.TrainersPicker do
  @moduledoc """
  The control for any setting that names people: who can train a connection or a channel,
  who may message a connection, who can train a Telegram bot. Shared by the connection form
  (`PepeWeb.ConnectionsComponent`), each channel row (`PepeWeb.SeenChannelsComponent`) and
  the bot form (`PepeWeb.ChannelsLive`).

  Nobody wants to look up and type platform ids, so the list is picked from the people Pepe
  has heard write (`Pepe.SeenPeople`): everyone heard anywhere on the connection for the
  connection's list, those heard in one channel for that channel's. A mode comes first
  (inherit, everyone, no one, only these people, or the subset a field allows); the people
  only show for the last one, those with a name first in alphabetical order, then the ones
  known only by id, most recently heard first, each with a small pencil to give them a
  name, plus an input to add an id that has not written yet. An id already stored that Pepe
  never heard from still shows, as its id, and stays checked.

  What is stored is exactly what `Pepe.Webhooks.parse_trainers/1` produces (`["*"]`, `[]`, a
  list of ids, or `nil` for "no list of its own"), so nothing downstream changes. The form
  round-trips through a map under one field prefix: `mode`, `people[]` and `extra`.
  """
  use PepeWeb, :html
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI

  alias Pepe.Labels
  alias Pepe.SeenChannels
  alias Pepe.SeenPeople

  @type person :: %{id: String.t(), text: String.t(), label: String.t() | nil, name: String.t() | nil, channels: [String.t()]}

  @all_modes ~w(default * none list)

  @doc "The form's map for a stored list (or `nil`)."
  @spec form_value([String.t()] | nil) :: map()
  def form_value(nil), do: %{"mode" => "default", "people" => [], "extra" => ""}
  def form_value(["*"]), do: %{"mode" => "*", "people" => [], "extra" => ""}
  def form_value([]), do: %{"mode" => "none", "people" => [], "extra" => ""}
  def form_value(list) when is_list(list), do: %{"mode" => "list", "people" => Enum.map(list, &to_string/1), "extra" => ""}

  @doc """
  The stored list for what the form sent back: `nil` to inherit, `["*"]`, `[]`, or the ids
  checked plus any typed in `extra` (read with `Pepe.Webhooks.parse_trainers/1`). "Only these
  people" with nobody picked is no one.
  """
  @spec to_list(map() | nil) :: [String.t()] | nil
  def to_list(%{"mode" => "*"}), do: ["*"]
  def to_list(%{"mode" => "none"}), do: []

  def to_list(%{"mode" => "list"} = value) do
    checked = value |> Map.get("people", []) |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))
    typed = (Pepe.Webhooks.parse_trainers(value["extra"]) || []) |> Enum.reject(&(&1 == "*"))
    Enum.uniq(checked ++ typed)
  end

  def to_list(_value), do: nil

  @doc """
  The people heard on a connection (every channel) or in one channel of it, one entry per
  person with what to call them and the channels they wrote in: those with a name first,
  alphabetically, then those known only by id, the most recently heard first.
  """
  @spec people(String.t(), String.t() | nil) :: [person()]
  def people(connection, channel \\ nil) do
    names = Map.new(SeenChannels.list(connection), &{&1.channel, Labels.channel_row(&1).text})

    connection
    |> SeenPeople.list(channel)
    |> Enum.group_by(& &1.person)
    |> Enum.map(fn {id, rows} ->
      label = Enum.find_value(rows, & &1.label)
      name = Enum.find_value(rows, & &1.name)

      %{
        id: id,
        label: label,
        name: name,
        text: label || name || id,
        channels: rows |> Enum.sort_by(&(-&1.last_seen)) |> Enum.map(&Map.get(names, &1.channel, &1.channel)) |> Enum.uniq(),
        last_seen: rows |> Enum.map(& &1.last_seen) |> Enum.max()
      }
    end)
    |> Enum.sort_by(fn p -> if p.text == p.id, do: {1, -p.last_seen, p.id}, else: {0, String.downcase(p.text), p.id} end)
    |> Enum.map(&Map.delete(&1, :last_seen))
  end

  @doc "The people to offer: those heard, plus any stored id nobody has heard from, shown as its id."
  @spec with_stored([person()], map() | nil) :: [person()]
  def with_stored(people, value) do
    known = MapSet.new(people, & &1.id)
    stored = (value || %{}) |> Map.get("people", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    people ++
      for id <- Enum.uniq(stored), id != "", id not in known do
        %{id: id, text: id, label: nil, name: nil, channels: []}
      end
  end

  @doc """
  Handle the people's rename events for a component that renders the picker: `"rename_person"`
  opens the inline edit (assign `renaming_person`), `"save_person_label"` stores the typed
  label for that person on `connection`, `"clear_person_label"` removes it. Returns the socket.
  """
  @spec person_event(String.t(), map(), Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def person_event("rename_person", %{"person" => person}, socket, _connection),
    do: Phoenix.Component.assign(socket, renaming_person: person)

  def person_event("save_person_label", %{"person" => person} = params, socket, connection) when is_binary(connection) do
    SeenPeople.put_label(connection, person, params["label"])
    Phoenix.Component.assign(socket, renaming_person: nil)
  end

  def person_event("clear_person_label", %{"person" => person}, socket, connection) when is_binary(connection) do
    SeenPeople.put_label(connection, person, nil)
    Phoenix.Component.assign(socket, renaming_person: nil)
  end

  def person_event(_event, _params, socket, _connection), do: Phoenix.Component.assign(socket, renaming_person: nil)

  attr :id, :string, required: true
  attr :target, :any, required: true

  @doc """
  The form the inline rename of a person submits to. A `<form>` cannot nest inside another, and
  the picker always sits inside one, so the rename input points at this one by its id (the
  `form` attribute) and the component renders it outside its own form.
  """
  def rename_form(assigns) do
    ~H"""
    <form id={@id} phx-submit="save_person_label" phx-target={@target}></form>
    """
  end

  attr :id, :string, required: true
  attr :field, :string, required: true, doc: "the form field prefix, e.g. \"trainers\""
  attr :value, :map, default: nil, doc: "what the form holds now (see form_value/1)"
  attr :people, :list, required: true, doc: "people/2, before with_stored/2"
  attr :inherit_label, :string, required: true, doc: "what the first choice says the list falls back to"
  attr :modes, :list, default: @all_modes, doc: "the modes this field offers, in order"
  attr :compact, :boolean, default: false, doc: "the channel row's smaller controls"
  attr :rename_form, :string, default: nil, doc: "id of the rename_form/1 rendered outside; nil hides the pencils"
  attr :renaming, :string, default: nil, doc: "the person whose inline rename is open"
  attr :target, :any, default: nil, doc: "phx-target for the rename events"

  @doc "The mode select and, for \"only these people\", the checkbox list and the extra-id input."
  def trainers_picker(assigns) do
    value = assigns.value || form_value(nil)
    checked = value |> Map.get("people", []) |> List.wrap()

    assigns =
      assign(assigns,
        value: value,
        mode: value["mode"] || "default",
        checked: checked,
        options: with_stored(assigns.people, value),
        ctl: if(assigns.compact, do: [fld_sm(), "h-[36px] py-1 text-[14px]"], else: fld())
      )

    ~H"""
    <div id={@id} class={["min-w-0", (@compact && "flex flex-wrap items-center gap-2") || "space-y-2"]}>
      <select name={"#{@field}[mode]"} class={@ctl}>
        <option :if={"default" in @modes} value="default" selected={@mode == "default"}>{@inherit_label}</option>
        <option :if={"*" in @modes} value="*" selected={@mode == "*"}>{gettext("Everyone here")}</option>
        <option :if={"none" in @modes} value="none" selected={@mode == "none"}>{gettext("No one")}</option>
        <option :if={"list" in @modes} value="list" selected={@mode == "list"}>{gettext("Only these people")}</option>
      </select>

      <div :if={@mode == "list"} class={["min-w-0", (@compact && "basis-full") || ""]}>
        <p :if={@options == []} class="rounded-lg border border-dashed border-zinc-700 px-3 py-2 text-sm text-zinc-500">
          {gettext("Nobody has written here yet. Add an id below.")}
        </p>
        <div :if={@options != []} class="flex flex-wrap gap-x-4 gap-y-1.5">
          <span :for={p <- @options} class="flex items-center gap-2 text-sm text-zinc-300">
            <label class="flex items-center gap-2">
              <input type="checkbox" name={"#{@field}[people][]"} value={p.id} checked={p.id in @checked} class={checkbox_cls()} />
              <.named text={p.text} id={p.id} />
            </label>
            <span :if={p.channels != []} class="text-xs text-zinc-600">{gettext("in %{channels}", channels: Enum.join(p.channels, ", "))}</span>
            <button
              :if={@rename_form && @renaming != p.id && p.channels != []}
              type="button"
              phx-click="rename_person"
              phx-value-person={p.id}
              phx-target={@target}
              title={gettext("Rename")}
              class="text-zinc-600 transition hover:text-zinc-200"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <span :if={@rename_form && @renaming == p.id} class="flex items-center gap-1">
              <input type="hidden" name="person" value={p.id} form={@rename_form} />
              <input
                name="label"
                value={p.label || ""}
                form={@rename_form}
                maxlength="60"
                placeholder={gettext("Name")}
                class={[fld_sm(), "h-[32px] w-40 py-1 text-[13.5px]"]}
              />
              <button type="submit" form={@rename_form} class={[btn_ghost(), "h-[32px] px-2.5 text-[13px]"]}>{gettext("Save")}</button>
              <button
                type="button"
                phx-click="clear_person_label"
                phx-value-person={p.id}
                phx-target={@target}
                class={[btn_ghost(), "h-[32px] px-2.5 text-[13px]"]}
              >
                {gettext("Clear")}
              </button>
            </span>
          </span>
        </div>
        <input
          name={"#{@field}[extra]"}
          value={@value["extra"] || ""}
          placeholder={gettext("Add an id that has not written yet, or several separated by commas")}
          class={[@ctl, "mt-2", (@compact && "w-80") || ""]}
        />
      </div>
    </div>
    """
  end
end
