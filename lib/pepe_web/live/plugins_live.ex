defmodule PepeWeb.PluginsLive do
  @moduledoc """
  Plugins section: install, list and remove user plugins from the dashboard. Installing
  fetches the source (a GitHub repo, a `.tar.gz`, or a local path), runs the `Sentinel`
  security scan, and refuses a dangerous verdict unless you explicitly install anyway.
  A plugin runs with full access to the app, so this is an admin action, install only
  from a source you trust.
  """
  use PepeWeb, :live_view
  use Gettext, backend: Pepe.Gettext

  import PepeWeb.DashUI
  import PepeWeb.DashData

  alias Pepe.Config
  alias Pepe.Plugins

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pepe · Plugins",
       scope: params["scope"] || "all",
       companies: Config.companies(),
       new_company: false,
       packages: Plugins.packages(),
       src: "",
       scan: nil,
       blocked: nil,
       trust: false,
       working: false,
       settings_name: nil,
       settings_schema: [],
       settings_values: %{}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex h-screen bg-zinc-950 text-zinc-100">
      <.sidebar active="plugins" scope={@scope} companies={@companies} new_company={@new_company} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🧩"
          title={gettext("Plugins")}
          desc={gettext("Install channels and tools that load at runtime, no rebuild. The code is security-scanned first; a plugin runs with full access, so install only from a source you trust.")}
        />

        <div class="flex-1 space-y-6 overflow-y-auto p-6">
          <div class={card()}>
            <label class={lbl()}>{gettext("Install a plugin")}</label>

            <p class="mb-3 flex items-start gap-2 text-[15px] text-amber-300">
              <span class="mt-0.5">⚠️</span>
              <span>
                {gettext("A plugin is code that runs with full access to your data and this machine. Install one only from a source you know and trust, and review it first (use Scan). Never paste a link you don't understand.")}
              </span>
            </p>

            <form id="plugin-install" phx-submit="install" phx-change="src_change" class="flex gap-2">
              <input name="src" value={@src} autocomplete="off"
                placeholder={gettext("GitHub repo URL, a .tar.gz URL, or a local path")} class={fld()} />
              <button type="button" phx-click="scan" disabled={@working or @src == ""} class={btn_ghost()}>{gettext("Scan")}</button>
              <button type="submit" disabled={@working or @src == "" or not @trust} class={[btn(), "disabled:opacity-50"]}>
                {if @working, do: gettext("Working..."), else: gettext("Install")}
              </button>
            </form>

            <label class="mt-2 flex items-center gap-2 text-sm text-zinc-300">
              <input type="checkbox" checked={@trust} phx-click="toggle_trust" class="h-4 w-4 accent-orange-500" />
              {gettext("I trust this source and understand it runs with full access to this machine.")}
            </label>
            <p class={hlp()}>{gettext("A package carries a manifest.json; a bare .exs works too. Scanning is always safe, it never runs the code.")}</p>

            <div :if={@scan} class="mt-3">
              <.scan_report scan={@scan} />
              <button :if={@blocked} phx-click="install_force" disabled={@working or not @trust}
                class={[btn(), "mt-3 bg-red-600 hover:bg-red-500 disabled:opacity-50"]}>
                {gettext("Install anyway (I have reviewed it)")}
              </button>
            </div>
          </div>

          <div>
            <div class="mb-2 text-sm font-semibold uppercase tracking-wider text-zinc-500">{gettext("Installed")}</div>
            <div :if={@packages == []} class="rounded-xl border border-dashed border-zinc-800 p-8 text-center text-zinc-500">
              {gettext("No plugins installed yet.")}
            </div>
            <div :for={p <- @packages} class={[card(), "mb-2 flex items-start justify-between gap-3"]}>
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class="font-medium">{p.name}</span>
                  <span class="rounded bg-zinc-800 px-1.5 text-sm text-zinc-400">{p.kind}</span>
                </div>
                <div :if={manifest_desc(p)} class="mt-0.5 truncate text-[15px] text-zinc-400">{manifest_desc(p)}</div>
              </div>
              <div class="flex shrink-0 gap-1">
                <button :if={configurable?(p)} phx-click="configure" phx-value-name={p.name} class={btn_ghost()}>{gettext("Configure")}</button>
                <button phx-click="remove" phx-value-name={p.name}
                  data-confirm={gettext("Remove plugin %{name}?", name: p.name)}
                  class={[btn_ghost(), "text-red-400 hover:text-red-300"]}>{gettext("Remove")}</button>
              </div>
            </div>
          </div>
        </div>
      </main>

      <%!-- Plugin settings, driven by the manifest's config schema --%>
      <div :if={@settings_name} class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
        <div class="flex max-h-[85vh] w-full max-w-lg flex-col rounded-2xl border border-zinc-800 bg-zinc-950" phx-click-away="settings_cancel">
          <div class="border-b border-zinc-800 px-6 py-4 text-lg font-semibold">{gettext("Configure %{name}", name: @settings_name)}</div>
          <form phx-submit="settings_save" class="flex min-h-0 flex-1 flex-col">
            <div class="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
              <div :for={f <- @settings_schema}>
                <label class={lbl()}>{f["label"]}</label>
                <select :if={f["type"] == "select"} name={"cfg[" <> f["key"] <> "]"} class={fld()}>
                  <option :for={o <- f["options"] || []} value={o} selected={settings_val(@settings_values, f["key"]) == o}>{o}</option>
                </select>
                <input :if={f["type"] != "select"} name={"cfg[" <> f["key"] <> "]"}
                  value={settings_val(@settings_values, f["key"])} class={[fld(), f["type"] == "secret" && "font-mono"]} />
                <p :if={f["hint"]} class={hlp()}>{f["hint"]}</p>
                <p :if={f["type"] == "secret" and !f["hint"]} class={hlp()}>{gettext("Secret: write ${ENV_VAR} to keep it out of the config file.")}</p>
              </div>
            </div>
            <div class="flex gap-2 border-t border-zinc-800 px-6 py-4">
              <button type="submit" class={btn()}>{gettext("Save")}</button>
              <button type="button" phx-click="settings_cancel" class={btn_ghost()}>{gettext("Cancel")}</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  attr :scan, :map, required: true

  defp scan_report(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
      <div class="mb-2 flex items-center gap-2 text-[15px]">
        <span class={["rounded-full px-2.5 py-0.5 text-xs font-medium", verdict_badge(@scan.verdict)]}>
          {verdict_label(@scan.verdict)}
        </span>
        <span class="text-zinc-500">{gettext("Security scan")}</span>
      </div>
      <div :if={@scan.findings == []} class="text-sm text-zinc-500">{gettext("Nothing flagged.")}</div>
      <ul class="space-y-1 text-sm">
        <li :for={f <- @scan.findings} class="flex items-start gap-2">
          <span>{severity_icon(f.severity)}</span>
          <span class="font-mono text-zinc-400">{finding_where(f)}</span>
          <span class="rounded bg-zinc-800 px-1.5 text-xs text-zinc-400">{f.category}</span>
          <span class="min-w-0 truncate text-zinc-300">{f.match}</span>
        </li>
      </ul>
    </div>
    """
  end

  @impl true
  def handle_event("src_change", %{"src" => src}, socket),
    do: {:noreply, assign(socket, src: src, scan: nil, blocked: nil)}

  def handle_event("toggle_trust", _p, socket),
    do: {:noreply, assign(socket, trust: !socket.assigns.trust)}

  def handle_event("scan", _p, socket) do
    src = socket.assigns.src

    {:noreply,
     socket
     |> assign(working: true, scan: nil, blocked: nil)
     |> start_async(:plugin_scan, fn -> Plugins.scan(src) end)}
  end

  def handle_event("install", %{"src" => src}, socket) do
    socket = assign(socket, src: src)

    if socket.assigns.trust,
      do: {:noreply, start_install(socket, false)},
      else: {:noreply, put_flash(socket, :error, gettext("Confirm you trust the source before installing."))}
  end

  def handle_event("install_force", _p, socket) do
    if socket.assigns.trust,
      do: {:noreply, start_install(socket, true)},
      else: {:noreply, put_flash(socket, :error, gettext("Confirm you trust the source before installing."))}
  end

  def handle_event("remove", %{"name" => name}, socket) do
    Plugins.remove(name)
    {:noreply, socket |> assign(packages: Plugins.packages()) |> put_flash(:info, gettext("Removed %{name}.", name: name))}
  end

  def handle_event("configure", %{"name" => name}, socket) do
    {:noreply,
     assign(socket,
       settings_name: name,
       settings_schema: Plugins.config_schema(name),
       settings_values: Config.plugin_config(name)
     )}
  end

  def handle_event("settings_cancel", _p, socket), do: {:noreply, assign(socket, settings_name: nil)}

  def handle_event("settings_save", params, socket) do
    name = socket.assigns.settings_name

    cleaned =
      (params["cfg"] || %{})
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    Config.put_plugin_config(name, cleaned)

    {:noreply,
     socket
     |> assign(settings_name: nil)
     |> put_flash(:info, gettext("Saved settings for %{name}.", name: name))}
  end

  def handle_event("set_scope", params, socket), do: {:noreply, set_scope(socket, params, "/plugins")}

  def handle_event("toggle_new_company", _p, socket),
    do: {:noreply, assign(socket, new_company: !socket.assigns.new_company)}

  def handle_event("company_add", params, socket), do: {:noreply, add_company(socket, params)}

  defp start_install(socket, force?) do
    src = socket.assigns.src

    socket
    |> assign(working: true, blocked: nil)
    |> start_async(:plugin_install, fn -> Plugins.install(src, force: force?) end)
  end

  @impl true
  def handle_async(:plugin_scan, {:ok, %{} = scan}, socket),
    do: {:noreply, assign(socket, working: false, scan: scan)}

  def handle_async(:plugin_scan, _other, socket),
    do: {:noreply, socket |> assign(working: false) |> put_flash(:error, gettext("Could not scan that source."))}

  def handle_async(:plugin_install, {:ok, {:ok, name, scan}}, socket) do
    {:noreply,
     socket
     |> assign(working: false, packages: Plugins.packages(), scan: scan, blocked: nil, src: "", trust: false)
     |> put_flash(:info, gettext("Installed %{name}.", name: name))}
  end

  def handle_async(:plugin_install, {:ok, {:error, {:unsafe, scan}}}, socket) do
    {:noreply,
     socket
     |> assign(working: false, scan: scan, blocked: true)
     |> put_flash(:error, gettext("Refused: the security scan flagged this plugin as dangerous."))}
  end

  def handle_async(:plugin_install, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(working: false) |> put_flash(:error, gettext("Install failed: %{r}", r: inspect(reason)))}

  def handle_async(:plugin_install, _other, socket),
    do: {:noreply, socket |> assign(working: false) |> put_flash(:error, gettext("Install crashed."))}

  defp manifest_desc(%{manifest: %{"description" => d}}) when is_binary(d), do: d
  defp manifest_desc(_), do: nil

  defp configurable?(%{manifest: %{"config" => fields}}) when is_list(fields), do: fields != []
  defp configurable?(_), do: false

  defp settings_val(values, key), do: to_string(Map.get(values, key, ""))

  defp finding_where(%{file: file, line: line}) when is_binary(file), do: "#{file}:#{line}"
  defp finding_where(%{line: line}), do: "line #{line}"

  defp verdict_badge(:danger), do: "bg-red-500/15 text-red-400"
  defp verdict_badge(:caution), do: "bg-amber-500/15 text-amber-300"
  defp verdict_badge(_), do: "bg-green-500/15 text-green-400"

  defp verdict_label(:danger), do: gettext("danger")
  defp verdict_label(:caution), do: gettext("caution")
  defp verdict_label(_), do: gettext("clean")

  defp severity_icon(:danger), do: "🚫"
  defp severity_icon(:caution), do: "⚠️"
  defp severity_icon(_), do: "•"
end
