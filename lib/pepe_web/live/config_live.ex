defmodule PepeWeb.ConfigLive do
  @moduledoc """
  The raw config-file editor: show `~/.pepe/config.json`, let the operator edit it,
  and save it back - validated as JSON first, so a broken file can't be written.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI

  alias Pepe.Config

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Config",
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
       can_self_update: not Pepe.Update.running_from_source?()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="config" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="⚙️"
          title={gettext("Configuration file")}
          desc={gettext("The raw config.json the runtime reads. Edit and save; it's validated as JSON first, so a broken file is refused. Secrets stay as ${ENV_VAR} references, resolved at read time (never stored raw).")}
        >
          <form phx-change="set_locale" class="flex items-center gap-2">
            <label for="locale" class="text-sm text-zinc-400">{gettext("Language")}</label>
            <select
              id="locale"
              name="locale"
              class="rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100"
            >
              <option :for={{code, label} <- @locales} value={code} selected={code == @locale}>{label}</option>
            </select>
          </form>
          <button :if={@can_self_update and @update in [nil, :up_to_date]} phx-click="check_update" class={btn_ghost()}>
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
          <button phx-click="config_reload" class={btn_ghost()}>{gettext("Reload from disk")}</button>
        </.view_header>

        <div class="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto p-6">
          <.form_section title={gettext("Media")}>
            <div class="grid gap-6 md:grid-cols-2">
              <form phx-submit="media_tts_save" class="space-y-3">
                <div class="text-sm font-medium text-zinc-200">{gettext("Voice replies (text-to-speech)")}</div>
                <p class={hlp()}>
                  {gettext("Reply to a voice note with a voice note. Needs a model connection serving an OpenAI-compatible /audio/speech.")}
                </p>
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
                <button type="submit" class={btn()}>{gettext("Save")}</button>
              </form>

              <form phx-submit="media_audio_save" class="space-y-3">
                <div class="text-sm font-medium text-zinc-200">{gettext("Voice-note transcription")}</div>
                <p class={hlp()}>
                  {gettext("Unset, a connection already known to transcribe (OpenAI, Groq) is used automatically.")}
                </p>
                <div>
                  <label class={lbl()} for="audio_model">{gettext("Model connection")}</label>
                  <select id="audio_model" name="model" class={fld()}>
                    <option value="" selected={@media_audio["model"] in [nil, ""]}>{gettext("Auto-detect")}</option>
                    <option :for={m <- @model_names} value={m} selected={m == @media_audio["model"]}>{m}</option>
                  </select>
                </div>
                <div>
                  <label class={lbl()} for="audio_command">{gettext("Or a local command")}</label>
                  <input
                    id="audio_command"
                    name="command"
                    type="text"
                    value={@media_audio["command"]}
                    placeholder="whisper {file}"
                    class={fld()}
                  />
                </div>
                <div class="grid grid-cols-3 gap-3">
                  <div>
                    <label class={lbl()} for="audio_language">{gettext("Language")}</label>
                    <input id="audio_language" name="language" type="text" value={@media_audio["language"]} class={fld()} />
                  </div>
                  <div>
                    <label class={lbl()} for="audio_max_mb">{gettext("Max MB")}</label>
                    <input id="audio_max_mb" name="max_mb" type="number" value={@media_audio["max_mb"]} class={fld()} />
                  </div>
                  <div>
                    <label class={lbl()} for="audio_timeout">{gettext("Timeout (s)")}</label>
                    <input id="audio_timeout" name="timeout" type="number" value={@media_audio["timeout"]} class={fld()} />
                  </div>
                </div>
                <label class="flex items-center gap-2 text-sm text-zinc-300">
                  <input type="checkbox" name="echo" value="true" checked={@media_audio["echo"] == true} class="h-4 w-4 accent-orange-500" />
                  {gettext("Echo the transcript back before answering")}
                </label>
                <button type="submit" class={btn()}>{gettext("Save")}</button>
              </form>
            </div>
          </.form_section>

          <form phx-submit="config_save" class="flex min-h-0 flex-1 flex-col gap-3">
            <textarea
              name="json"
              spellcheck="false"
              class="min-h-0 w-full flex-1 resize-none rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm leading-relaxed text-zinc-100 outline-none focus:border-orange-500 focus:ring-1 focus:ring-orange-500"
            >{@config_text}</textarea>
            <div class="flex items-center gap-3">
              <button type="submit" class={btn()}>{gettext("Save config")}</button>
              <span class="text-sm text-zinc-500">
                {gettext("Saving replaces the whole file. Invalid JSON is rejected.")}
              </span>
            </div>
          </form>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_info({:update_result, {:newer, v}}, socket), do: {:noreply, assign(socket, update: v)}

  def handle_info({:update_result, :up_to_date}, socket),
    do: {:noreply, socket |> assign(update: :up_to_date) |> put_flash(:info, gettext("You're on the latest version."))}

  def handle_info({:update_result, :error}, socket),
    do: {:noreply, socket |> assign(update: nil) |> put_flash(:error, gettext("Couldn't check for updates."))}

  @impl true
  def handle_event("set_locale", %{"locale" => code}, socket) do
    if Config.known_locale?(code) do
      Config.set_locale(code)
      # Re-navigate so the LiveLocale on_mount re-applies the locale to a fresh process and the whole
      # page re-renders translated (this process already had the old locale set at mount time).
      {:noreply, push_navigate(socket, to: "/config?scope=#{socket.assigns.scope}")}
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
        {:ok, :updated, v} -> {:info, gettext("Updated to v%{v}. Restart Pepe to run the new version.", v: v)}
        {:ok, :up_to_date, _} -> {:info, gettext("Already on the latest version.")}
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
