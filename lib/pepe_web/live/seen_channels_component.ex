defmodule PepeWeb.SeenChannelsComponent do
  @moduledoc """
  The channels one connection has heard from (`Pepe.SeenChannels`), under its card on the
  Channels page: a count that opens into the list, and on each row the settings that have
  two levels, changed in place.

  Every setting here has a default on the connection (the whole Slack workspace, the whole
  bot) and may have a value of the channel's own, which is the stronger one and wins for that
  channel only: the agent it is bound to, whether it answers without an @mention, and who can
  train it. Each row says, per setting, whether what applies is the channel's own or comes
  from the connection, and offers "use the connection's", which removes only the channel's
  own value. A direct message is a channel too and carries its own values the same way.

  Used under a webhook connection (`controls: :webhook`, all three settings) and under a
  Telegram bot (`controls: :telegram`, the agent only: Telegram keeps mentions and trainers
  per bot). A webhook channel that has a value of its own but was never heard from (set from
  the CLI before the first message, say) is listed too, so that value is never invisible.

  Assigns: `connection` (the webhook slug or bot name), `provider`, `agent` (the connection's
  own, the default a row inherits), `agents` (what the agent picker offers), `trainers` (the
  connection's list), `mention_optional` (the connection's default), `mention_gated` (whether
  the provider gates on mentions at all) and `controls`.
  """
  use PepeWeb, :live_component
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.TrainersPicker, only: [rename_form: 1, trainers_picker: 1]

  alias Pepe.Agent.Session
  alias Pepe.Config
  alias Pepe.SeenChannels
  alias PepeWeb.TrainersPicker

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:drafts, fn -> %{} end)
     |> assign_new(:renaming, fn -> nil end)
     |> assign_new(:renaming_person, fn -> nil end)
     |> assign_new(:agent, fn -> nil end)
     |> assign_new(:trainers, fn -> nil end)
     |> assign_new(:mention_optional, fn -> false end)
     |> assign_new(:mention_gated, fn -> false end)
     |> load_rows()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-3 border-t border-zinc-800 pt-3 text-sm">
      <p :if={@rows == []} class="text-zinc-600">{gettext("No channels heard from yet. They appear here after the first message.")}</p>
      <button
        :if={@rows != []}
        type="button"
        phx-click="toggle"
        phx-target={@myself}
        class="inline-flex items-center gap-1.5 text-zinc-400 transition hover:text-zinc-100"
      >
        <span>{ngettext("%{count} channel", "%{count} channels", length(@rows))}</span>
        <span class="text-xs">{(@open && "▾") || "▸"}</span>
      </button>

      <div :if={@open} class="mt-3 space-y-2">
        <p class="text-xs text-zinc-500">
          {gettext("Each setting is the connection's unless the channel has one of its own, which then wins for that channel only.")}
        </p>
        <div :for={{r, i} <- Enum.with_index(@rows)} class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <.named :if={@renaming != r.channel} text={r.text} id={r.channel} class="text-zinc-200" />
              <button
                :if={@renaming != r.channel and r.recorded?}
                type="button"
                phx-click="rename"
                phx-value-channel={r.channel}
                phx-target={@myself}
                title={gettext("Rename")}
                class="text-zinc-600 transition hover:text-zinc-200"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
              <%!-- Display only, apart from the provider's own name: the id stays the key. --%>
              <form :if={@renaming == r.channel} phx-submit="save_label" phx-target={@myself} class="flex flex-wrap items-center gap-1">
                <input type="hidden" name="channel" value={r.channel} />
                <input name="label" value={r.label || ""} maxlength="60" placeholder={r.name || r.channel} class={[fld_sm(), "h-[32px] w-48 py-1 text-[13.5px]"]} />
                <button type="submit" class={[btn_ghost(), "h-[32px] px-2.5 text-[13px]"]}>{gettext("Save")}</button>
                <button type="button" phx-click="clear_label" phx-value-channel={r.channel} phx-target={@myself} class={[btn_ghost(), "h-[32px] px-2.5 text-[13px]"]}>
                  {gettext("Clear")}
                </button>
              </form>
              <span :if={r.kind} class={tag(:muted)}>{kind_label(r.kind)}</span>
            </div>
            <span class="text-xs text-zinc-500">{last_activity(r.last_seen)}</span>
          </div>

          <div class="mt-3 space-y-2">
            <%!-- Agent --%>
            <form id={"#{@id}-agent-#{i}"} phx-change="bind_agent" phx-target={@myself} data-channel={r.channel} class={row_cls()}>
              <input type="hidden" name="channel" value={r.channel} />
              <label class={row_lbl()}>{gettext("Agent")}</label>
              <select name="agent" class={ctl()}>
                <option value="" selected={is_nil(r.agent)}>{default_agent_label(@controls, @agent)}</option>
                <option :for={a <- @agents} value={a} selected={r.agent == a}>{a}</option>
              </select>
              <.origin own={not is_nil(r.agent)} controls={@controls} />
              <.reset :if={r.agent} event="reset_agent" channel={r.channel} target={@myself} controls={@controls} />
            </form>

            <%!-- Mention. Not on a direct message, which always answers: a setting there would mislead. --%>
            <form
              :if={@controls == :webhook and @mention_gated and r.kind != "dm"}
              id={"#{@id}-mention-#{i}"}
              phx-change="set_mention"
              phx-target={@myself}
              data-channel={r.channel}
              class={row_cls()}
            >
              <input type="hidden" name="channel" value={r.channel} />
              <label class={row_lbl()}>{gettext("Mention")}</label>
              <select name="mention" class={ctl()}>
                <option value="" selected={is_nil(r.mention)}>
                  {gettext("Use the connection's: %{value}", value: mention_label(@mention_optional))}
                </option>
                <option value="optional" selected={r.mention == true}>{mention_label(true)}</option>
                <option value="required" selected={r.mention == false}>{mention_label(false)}</option>
              </select>
              <.origin own={not is_nil(r.mention)} controls={@controls} />
              <.reset :if={not is_nil(r.mention)} event="reset_mention" channel={r.channel} target={@myself} controls={@controls} />
            </form>

            <%!-- Trainers: picked from the people heard in this very channel. The form is a draft
                 until Save, so switching to "only these people" does not store "no one" meanwhile. --%>
            <form
              :if={@controls == :webhook}
              id={"#{@id}-trainers-#{i}"}
              phx-change="trainers_change"
              phx-submit="save_trainers"
              phx-target={@myself}
              data-channel={r.channel}
              class={row_cls()}
            >
              <input type="hidden" name="channel" value={r.channel} />
              <label class={row_lbl()}>{gettext("Who can train")}</label>
              <.trainers_picker
                id={"#{@id}-trainers-picker-#{i}"}
                field="trainers"
                value={Map.get(@drafts, r.channel) || TrainersPicker.form_value(r.own_trainers)}
                people={r.people}
                inherit_label={gettext("The connection's: %{who}", who: trainers_summary(@trainers))}
                compact
                rename_form={"#{@id}-rename-person-#{i}"}
                renaming={@renaming_person}
                target={@myself}
              />
              <button type="submit" class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>{gettext("Save")}</button>
              <.origin own={not is_nil(r.own_trainers)} controls={@controls} />
              <.reset :if={r.own_trainers} event="reset_trainers" channel={r.channel} target={@myself} controls={@controls} />
            </form>
            <%!-- Outside the trainers form on purpose: a person's inline rename submits here. --%>
            <.rename_form :if={@controls == :webhook} id={"#{@id}-rename-person-#{i}"} target={@myself} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :own, :boolean, required: true
  attr :controls, :atom, required: true

  # Where the value in force comes from: the channel's own, or inherited from the connection.
  defp origin(assigns) do
    ~H"""
    <span :if={@own} class={tag(:warn)}>{gettext("own")}</span>
    <span :if={!@own} class={tag(:muted)}>{(@controls == :telegram && gettext("from the bot")) || gettext("from the connection")}</span>
    """
  end

  attr :event, :string, required: true
  attr :channel, :string, required: true
  attr :target, :any, required: true
  attr :controls, :atom, required: true

  # Removes only the channel's own value; the connection's default applies again.
  defp reset(assigns) do
    ~H"""
    <button type="button" phx-click={@event} phx-value-channel={@channel} phx-target={@target} class={[btn_ghost(), "h-[36px] px-3 text-[13.5px]"]}>
      {(@controls == :telegram && gettext("Use the bot's")) || gettext("Use the connection's")}
    </button>
    """
  end

  defp row_cls, do: "flex flex-wrap items-center gap-2"
  defp row_lbl, do: "w-24 shrink-0 text-xs text-zinc-500"
  defp ctl, do: [fld_sm(), "h-[36px] py-1 text-[14px]"]

  @impl true
  def handle_event("toggle", _params, socket), do: {:noreply, assign(socket, open: !socket.assigns.open)}

  # Only an agent the picker offered: the list is already scoped to the connection's project,
  # which is the same rule `/agent` applies in the chat. Blank is the reset.
  def handle_event("bind_agent", %{"channel" => channel, "agent" => agent}, socket) do
    cond do
      agent == "" -> bind_agent(socket, channel, nil)
      agent in socket.assigns.agents -> bind_agent(socket, channel, agent)
      true -> :ok
    end

    {:noreply, load_rows(socket)}
  end

  def handle_event("reset_agent", %{"channel" => channel}, socket) do
    bind_agent(socket, channel, nil)
    {:noreply, load_rows(socket)}
  end

  def handle_event("set_mention", %{"channel" => channel, "mention" => value}, socket) do
    Config.put_channel_mention(mention_key(socket.assigns.connection, channel), mention_value(value))
    {:noreply, load_rows(socket)}
  end

  def handle_event("reset_mention", %{"channel" => channel}, socket) do
    Config.put_channel_mention(mention_key(socket.assigns.connection, channel), nil)
    {:noreply, load_rows(socket)}
  end

  # Keep what the row's form holds so the people list shows as the mode changes; stored on Save.
  def handle_event("trainers_change", %{"channel" => channel, "trainers" => value}, socket) do
    {:noreply, assign(socket, drafts: Map.put(socket.assigns.drafts, channel, value))}
  end

  # "Use the connection's" picked as the mode is the same as the reset.
  def handle_event("save_trainers", %{"channel" => channel, "trainers" => value}, socket) do
    Config.put_channel_trainers(mention_key(socket.assigns.connection, channel), TrainersPicker.to_list(value))
    {:noreply, socket |> assign(drafts: Map.delete(socket.assigns.drafts, channel)) |> load_rows()}
  end

  def handle_event("reset_trainers", %{"channel" => channel}, socket) do
    Config.put_channel_trainers(mention_key(socket.assigns.connection, channel), nil)
    {:noreply, socket |> assign(drafts: Map.delete(socket.assigns.drafts, channel)) |> load_rows()}
  end

  def handle_event("rename", %{"channel" => channel}, socket), do: {:noreply, assign(socket, renaming: channel)}

  def handle_event("save_label", %{"channel" => channel, "label" => label}, socket) do
    SeenChannels.put_label(socket.assigns.connection, channel, label)
    {:noreply, socket |> assign(renaming: nil) |> load_rows()}
  end

  def handle_event("clear_label", %{"channel" => channel}, socket) do
    SeenChannels.put_label(socket.assigns.connection, channel, nil)
    {:noreply, socket |> assign(renaming: nil) |> load_rows()}
  end

  # The people's inline rename inside the trainers pickers (see PepeWeb.TrainersPicker).
  def handle_event(event, params, socket) when event in ["rename_person", "save_person_label", "clear_person_label"] do
    {:noreply, event |> TrainersPicker.person_event(params, socket, socket.assigns.connection) |> load_rows()}
  end

  # The durable binding, plus the conversation already open in that channel, if any: a webhook
  # session only reasserts a binding that exists (Pepe.Webhooks.apply_channel_binding/3), so
  # clearing one has to hand the open conversation back to the connection's agent here, the
  # way `/agent none` does in the chat. Telegram resolves the agent on every message itself.
  defp bind_agent(%{assigns: assigns} = socket, channel, agent) do
    key = session_key(assigns, channel)
    Config.bind_channel_agent(key, agent)

    if assigns.controls == :webhook and Registry.lookup(Pepe.Agent.Registry, key) != [] do
      Session.set_agent(key, agent || assigns.agent || Config.default_agent_name())
    end

    socket
  end

  defp mention_value("optional"), do: true
  defp mention_value("required"), do: false
  defp mention_value(_blank), do: nil

  defp load_rows(socket) do
    %{connection: connection, controls: controls} = socket.assigns
    seen = SeenChannels.list(connection)
    rows = Enum.map(seen ++ unseen_with_own_values(connection, controls, seen), &row(&1, socket.assigns))
    assign(socket, rows: rows)
  end

  # A channel that has a value of its own (trainers or mention) but never sent a message since
  # this started being recorded: listed with no activity, so the value can still be seen and undone.
  defp unseen_with_own_values(connection, :webhook, seen) do
    prefix = connection <> ":"
    known = MapSet.new(seen, & &1.channel)
    keys = Map.keys(Config.channel_trainers_all()) ++ Map.keys(Config.channel_mentions_all())

    for key <- Enum.uniq(keys),
        String.starts_with?(key, prefix),
        channel = String.replace_prefix(key, prefix, ""),
        channel not in known do
      %{channel: channel, name: nil, label: nil, kind: nil, last_seen: nil}
    end
    |> Enum.sort_by(& &1.channel)
  end

  defp unseen_with_own_values(_connection, _controls, _seen), do: []

  defp row(c, %{controls: controls, connection: connection} = assigns) do
    channel_key = mention_key(connection, c.channel)

    %{
      channel: c.channel,
      name: c.name,
      label: c.label,
      text: c.label || c.name || c.channel,
      # A channel only known from a setting of its own has no row to hold a label.
      recorded?: not is_nil(c.last_seen),
      kind: c.kind,
      last_seen: c.last_seen,
      agent: Config.channel_agent(session_key(assigns, c.channel)),
      mention: if(controls == :webhook, do: Config.channel_mention(channel_key)),
      own_trainers: if(controls == :webhook, do: Config.channel_trainers(channel_key)),
      people: if(controls == :webhook, do: TrainersPicker.people(connection, c.channel), else: [])
    }
  end

  # Telegram's binding is keyed by bot and chat (Pepe.Gateways.Telegram); a webhook's by provider,
  # agent and channel (Pepe.Webhooks.session_key/2), the same keys the chat commands write.
  defp session_key(%{controls: :telegram, connection: bot}, channel),
    do: Pepe.Gateways.Telegram.channel_session_key(bot, channel)

  defp session_key(%{provider: provider, agent: agent}, channel),
    do: Pepe.Webhooks.session_key(%{"provider" => provider, "agent" => agent}, channel)

  defp mention_key(connection, channel), do: Pepe.Webhooks.mention_key(%{"slug" => connection}, channel)

  defp default_agent_label(:telegram, nil), do: gettext("The bot's: the default agent")
  defp default_agent_label(:telegram, agent), do: gettext("The bot's: %{agent}", agent: agent)
  defp default_agent_label(_controls, nil), do: gettext("The connection's: the default agent")
  defp default_agent_label(_controls, agent), do: gettext("The connection's: %{agent}", agent: agent)

  defp mention_label(true), do: gettext("answers without a mention")
  defp mention_label(_required), do: gettext("requires a mention")

  defp kind_label("dm"), do: gettext("direct message")
  defp kind_label(_kind), do: gettext("group")

  defp trainers_summary(["*"]), do: gettext("everyone")
  defp trainers_summary([]), do: gettext("no one")
  defp trainers_summary(list) when is_list(list), do: Enum.join(list, ", ")
  defp trainers_summary(_none), do: gettext("everyone")

  defp last_activity(nil), do: gettext("no message yet")

  defp last_activity(ts) do
    diff = max(System.os_time(:second) - ts, 0)

    cond do
      diff < 60 -> gettext("active just now")
      diff < 3_600 -> ngettext("active %{count} minute ago", "active %{count} minutes ago", div(diff, 60))
      diff < 86_400 -> ngettext("active %{count} hour ago", "active %{count} hours ago", div(diff, 3_600))
      true -> ngettext("active %{count} day ago", "active %{count} days ago", div(diff, 86_400))
    end
  end
end
