defmodule PepeWeb.ConfigLive do
  @moduledoc """
  The Configuration page: language, updates, voice settings, the change history and the raw
  `~/.pepe/config.json` editor (validated as JSON first, so a broken file can't be written), one
  tab each. Every section saves on its own.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe: " <> gettext("Configuration"),
       tab: tab_from(params["tab"]),
       version: Pepe.Update.current(),
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       config_text: read_config(),
       locale: Config.locale(),
       locales: Config.locales(),
       model_names: Config.models() |> Enum.map(& &1.name),
       media_tts: Config.media()["tts"] || %{},
       media_audio: Config.media()["audio"] || %{},
       # nil = not checked yet · :checking · :up_to_date · a version string when newer.
       update: nil,
       can_self_update: not Pepe.Update.running_from_source?(),
       journal: Config.Journal.recent(15)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="config" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header active="config"
          icon="⚙️"
          title={gettext("Configuration")}
          desc={gettext("Language, updates, voice and the settings file. Each section saves on its own.")}
        />

        <div class={[body_cls(), "flex flex-col gap-6"]}>
          <.tabs tabs={config_tabs()} active={@tab} event="config_tab" />

          <div :if={@tab == "general"} class="space-y-6">
            <.form_section title={gettext("Language")}>
              <form id="locale-form" phx-change="set_locale" class="max-w-sm">
                <label for="locale" class={lbl()}>{gettext("Dashboard language")}</label>
                <select id="locale" name="locale" class={fld()}>
                  <option :for={{code, label} <- @locales} value={code} selected={code == @locale}>{label}</option>
                </select>
                <p class={hlp()}>{gettext("Changes as soon as you pick one.")}</p>
              </form>
            </.form_section>

            <.form_section title={gettext("Updates")}>
              <div class="space-y-4">
                <.meta_list>
                  <:item label={gettext("Version")}>v{@version}</:item>
                </.meta_list>
                <p :if={not @can_self_update} class={hlp()}>
                  {gettext("This install runs from source. Update it with git pull.")}
                </p>
                <div :if={@can_self_update} class="flex flex-wrap items-center gap-2">
                  <button :if={@update in [nil, :up_to_date]} phx-click="check_update" class={btn_ghost()}>
                    {gettext("Check for updates")}
                  </button>
                  <button :if={@update == :checking} disabled class={btn_ghost()}>{gettext("Checking...")}</button>
                  <a
                    :if={is_binary(@update)}
                    href={"https://github.com/pepe-agent/pepe/releases/tag/v#{@update}"}
                    target="_blank"
                    rel="noopener"
                    class={btn_ghost()}
                  >
                    {gettext("View changelog ↗")}
                  </a>
                  <button
                    :if={is_binary(@update)}
                    phx-click="do_update"
                    data-confirm={gettext("Download and install v%{v} now? Restart Pepe afterward to run it.", v: @update)}
                    class={btn()}
                  >
                    {gettext("Update to v%{v}", v: @update)}
                  </button>
                </div>
              </div>
            </.form_section>
          </div>

          <div :if={@tab == "voice"} class="space-y-6">
            <.form_section title={gettext("Voice replies (text-to-speech)")}>
              <form id="tts-form" phx-submit="media_tts_save" class="space-y-6">
                <p class={hlp()}>
                  {gettext("Answers a voice message with a voice message. Needs a model connection that supports /audio/speech.")}
                </p>
                <div class="grid gap-6 sm:grid-cols-2">
                  <div>
                    <label class={lbl()} for="tts_model">{gettext("Model connection")}</label>
                    <select id="tts_model" name="model" class={fld()}>
                      <option value="" selected={@media_tts["model"] in [nil, ""]}>{gettext("Off")}</option>
                      <option :for={m <- @model_names} value={m} selected={m == @media_tts["model"]}>{m}</option>
                    </select>
                  </div>
                  <div>
                    <label class={lbl()} for="tts_voice">{gettext("Voice")}</label>
                    <input id="tts_voice" name="voice" type="text" value={@media_tts["voice"] || "alloy"} class={fld()} />
                  </div>
                </div>
                <button type="submit" class={btn()}>{gettext("Save")}</button>
              </form>
            </.form_section>

            <.form_section title={gettext("Voice message transcription")}>
              <form id="audio-form" phx-submit="media_audio_save" class="space-y-6">
                <p class={hlp()}>
                  {gettext("Leave blank to use a service known to transcribe audio (OpenAI, Groq).")}
                </p>
                <div class="grid gap-6 sm:grid-cols-2">
                  <div>
                    <label class={lbl()} for="audio_model">{gettext("Model connection")}</label>
                    <select id="audio_model" name="model" class={fld()}>
                      <option value="" selected={@media_audio["model"] in [nil, ""]}>{gettext("Auto-detect")}</option>
                      <option :for={m <- @model_names} value={m} selected={m == @media_audio["model"]}>{m}</option>
                    </select>
                  </div>
                  <div>
                    <label class={lbl()} for="audio_command">{gettext("Or a command on this computer")}</label>
                    <input
                      id="audio_command"
                      name="command"
                      type="text"
                      value={@media_audio["command"]}
                      placeholder="whisper {file}"
                      class={fld()}
                    />
                  </div>
                </div>
                <div class="grid gap-6 sm:grid-cols-3">
                  <div>
                    <label class={lbl()} for="audio_language">{gettext("Language")}</label>
                    <input id="audio_language" name="language" type="text" value={@media_audio["language"]} class={fld()} />
                    <p class={hlp()}>
                      {gettext("Language spoken in the audio (pt, en, es). Blank detects it automatically.")}
                    </p>
                  </div>
                  <div>
                    <label class={lbl()} for="audio_max_mb">{gettext("Max MB")}</label>
                    <input id="audio_max_mb" name="max_mb" type="number" value={@media_audio["max_mb"]} class={fld()} />
                    <p class={hlp()}>{gettext("Largest voice message accepted, in MB. Bigger ones are refused.")}</p>
                  </div>
                  <div>
                    <label class={lbl()} for="audio_timeout">{gettext("Timeout (s)")}</label>
                    <input id="audio_timeout" name="timeout" type="number" value={@media_audio["timeout"]} class={fld()} />
                    <p class={hlp()}>{gettext("Seconds to wait for the transcription before giving up.")}</p>
                  </div>
                </div>
                <label class="flex items-center gap-2 text-sm text-zinc-300">
                  <input type="checkbox" name="echo" value="true" checked={@media_audio["echo"] == true} class={checkbox_cls()} />
                  {gettext("Send the transcribed text back before answering")}
                </label>
                <button type="submit" class={btn()}>{gettext("Save")}</button>
              </form>
            </.form_section>
          </div>

          <div :if={@tab == "history"} class="space-y-6">
            <.form_section title={gettext("Recent changes")}>
              <p class={hlp()}>
                {gettext("Who changed config.json and when. The values themselves are never recorded.")}
              </p>
              <.empty_state :if={@journal == []}>{gettext("No changes recorded yet.")}</.empty_state>
              <div :if={@journal != []} class="max-h-[28rem] space-y-1.5 overflow-y-auto text-sm">
                <div :for={entry <- @journal} class="flex items-center gap-2 border-b border-zinc-800/60 py-1.5 last:border-0">
                  <span class="w-36 shrink-0 font-mono text-xs text-zinc-500">{local_datetime(entry["at"])}</span>
                  <span class="w-28 shrink-0 truncate text-zinc-300">{entry["source"]}</span>
                  <span class="min-w-0 flex-1 truncate text-zinc-500">{Enum.join(entry["changed"] || [], ", ")}</span>
                  <span :if={entry["external"]} class={[tag(:warn), "shrink-0"]}>
                    {gettext("external")}
                  </span>
                </div>
              </div>
            </.form_section>
          </div>

          <div :if={@tab == "file"} class="space-y-6">
            <.form_section title={gettext("config.json")}>
              <form id="config-form" phx-submit="config_save" class="flex min-h-0 flex-1 flex-col gap-3">
                <p class={hlp()}>
                  {gettext("Write secrets as ${ENV_VAR}. Pepe reads them from the environment and never saves the value.")}
                </p>
                <textarea
                  name="json"
                  spellcheck="false"
                  class="min-h-[360px] w-full flex-1 resize-none rounded-[12px] border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm leading-relaxed text-zinc-100 outline-none focus:border-orange-500 focus:ring-1 focus:ring-orange-500"
                >{@config_text}</textarea>
                <div class="flex flex-wrap items-center gap-3">
                  <button type="submit" class={btn()}>{gettext("Save config")}</button>
                  <button type="button" phx-click="config_reload" class={btn_ghost()}>{gettext("Reload from disk")}</button>
                  <span class="text-sm text-zinc-500">
                    {gettext("Saving replaces the whole file. Invalid JSON is rejected.")}
                  </span>
                </div>
              </form>
            </.form_section>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp config_tabs do
    [
      {"general", gettext("General")},
      {"voice", gettext("Voice")},
      {"history", gettext("History")},
      {"file", gettext("Settings file")}
    ]
  end

  defp tab_from(tab) when tab in ["general", "voice", "history", "file"], do: tab
  defp tab_from(_), do: "general"

  @impl true
  def handle_info({:update_result, {:newer, v}}, socket), do: {:noreply, assign(socket, update: v)}

  def handle_info({:update_result, :up_to_date}, socket),
    do: {:noreply, socket |> assign(update: :up_to_date) |> put_flash(:info, gettext("You're on the latest version."))}

  def handle_info({:update_result, :error}, socket),
    do: {:noreply, socket |> assign(update: nil) |> put_flash(:error, gettext("Couldn't check for updates."))}

  @impl true
  def handle_event("config_tab", %{"tab" => tab}, socket), do: {:noreply, assign(socket, tab: tab_from(tab))}

  def handle_event("set_locale", %{"locale" => code}, socket) do
    if Config.known_locale?(code) do
      Config.set_locale(code)
      # Re-navigate so the LiveLocale on_mount re-applies the locale to a fresh process and the whole
      # page re-renders translated (this process already had the old locale set at mount time).
      {:noreply, push_navigate(socket, to: "/config?scope=#{socket.assigns.scope}&tab=#{socket.assigns.tab}")}
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown language."))}
    end
  end

  def handle_event("check_update", _p, socket) do
    parent = self()

    Task.start(fn -> send(parent, {:update_result, update_status()}) end)

    {:noreply, assign(socket, update: :checking)}
  end

  def handle_event("do_update", _p, socket) do
    flash =
      case Pepe.Update.run() do
        {:ok, :updated, v} -> {:info, gettext("Updated to v%{v}. Restart Pepe to use the new version.", v: v)}
        {:ok, :up_to_date, _} -> {:info, gettext("You already have the latest version.")}
        {:error, _} -> {:error, gettext("Update failed. Try `pepe update` from a terminal.")}
      end

    {:noreply, socket |> assign(update: nil) |> put_flash(elem(flash, 0), elem(flash, 1))}
  end

  def handle_event("config_save", %{"json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        # The operator edited the whole config as raw JSON; write it through the serialized path
        # so it doesn't race (and lose) a concurrent write from a running agent turn.
        Config.update(fn _ -> map end)
        Pepe.Gateways.Supervisor.reload_telegram()

        {:noreply,
         socket
         |> assign(config_text: pretty(map), projects: Config.project_slugs())
         |> put_flash(:info, gettext("Config saved."))}

      {:ok, _} ->
        {:noreply, put_flash(socket, :error, gettext("The top level must be a JSON object { ... }."))}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid JSON: %{msg}", msg: Exception.message(err)))}
    end
  end

  def handle_event("config_reload", _p, socket) do
    {:noreply, assign(socket, config_text: read_config())}
  end

  def handle_event("media_tts_save", params, socket) do
    case presence(params["model"]) do
      nil -> Config.put_media("tts", %{})
      model -> Config.put_media("tts", %{"model" => model, "voice" => presence(params["voice"]) || "alloy"})
    end

    {:noreply,
     socket
     |> assign(media_tts: Config.media()["tts"] || %{})
     |> put_flash(:info, gettext("Media settings saved."))}
  end

  def handle_event("media_audio_save", params, socket) do
    settings =
      %{}
      |> put_present("model", presence(params["model"]))
      |> put_present("command", presence(params["command"]))
      |> put_present("language", presence(params["language"]))
      |> put_present("max_mb", parse_int(params["max_mb"]))
      |> put_present("timeout", parse_int(params["timeout"]))
      |> Map.put("echo", params["echo"] == "true")

    Config.put_media("audio", settings)

    {:noreply,
     socket
     |> assign(media_audio: Config.media()["audio"] || %{})
     |> put_flash(:info, gettext("Media settings saved."))}
  end

  # Changing the project stays on this page; creating one jumps to its Agents.
  def handle_event("set_scope", %{"scope" => scope}, socket) do
    {:noreply, push_navigate(socket, to: "/config?scope=#{scope}")}
  end

  def handle_event("toggle_new_project", _p, socket) do
    {:noreply, assign(socket, new_project: !socket.assigns.new_project)}
  end

  def handle_event("project_add", %{"name" => name}, socket) do
    name = String.trim(name)

    case Config.add_project(name) do
      :ok -> {:noreply, push_navigate(socket, to: "/agents?scope=#{name}")}
      _ -> {:noreply, put_flash(socket, :error, gettext("Invalid or duplicate project name."))}
    end
  end

  defp update_status do
    case Pepe.Update.latest() do
      {:ok, v} -> if Pepe.Update.newer?(v), do: {:newer, v}, else: :up_to_date
      _ -> :error
    end
  end

  defp presence(nil), do: nil
  defp presence(v), do: v |> to_string() |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp parse_int(v) do
    case v |> to_string() |> String.trim() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp read_config do
    case File.read(Config.path()) do
      {:ok, body} -> body
      _ -> pretty(Config.load())
    end
  end

  defp pretty(map), do: Jason.encode!(map, pretty: true)
end
