defmodule PepeWeb.TokensLive do
  @moduledoc """
  API tokens section: mint, list and revoke the bearer tokens the `/v1` API accepts.
  With no token the API is open only to loopback; the first token locks it down, so
  every caller (local or remote) must then present one. A regular token's raw secret
  is shown once on creation and never stored - only its hash and a safe fingerprint
  prefix are kept. A **widget** token is the exception: it's meant to sit in public
  page source anyway, so its raw value stays retrievable here instead of forcing a
  rotation the moment someone loses their copy of the embed snippet.
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
       page_title: "Pepe · API tokens",
       scope: params["scope"] || "all",
       projects: Config.project_slugs(),
       new_project: false,
       tokens: Config.api_tokens(),
       token_project: nil,
       token_widget: false,
       token_usage: false,
       raw: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={shell_cls()}>
      <.sidebar active="tokens" scope={@scope} projects={@projects} new_project={@new_project} />
      <main class="flex min-w-0 flex-1 flex-col">
        <.view_header
          icon="🔑"
          title={gettext("API tokens")}
          desc={gettext("Bearer tokens for the OpenAI-compatible /v1 API. With no token, only loopback (localhost) callers get through. Minting the first token requires one from everyone else too, local or remote: that's what secures a network-exposed server.")}
        />

        <div class="flex-1 overflow-y-auto p-4 sm:p-6">
          <div :if={@raw} class="mb-6 max-w-2xl rounded-lg border border-amber-700/60 bg-amber-950/40 p-3">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0 text-sm">
                <span class="font-semibold text-amber-200">{gettext("Copy this token now")}</span>
                <span class="text-amber-200/70">- {gettext("shown only once, store it somewhere safe.")}</span>
              </div>
              <button phx-click="token_dismiss" class="shrink-0 text-sm text-amber-200/70 hover:text-amber-200">{gettext("Dismiss")}</button>
            </div>
            <div class="mt-2 flex items-center gap-2">
              <code class="min-w-0 flex-1 select-all truncate rounded-lg border border-amber-800/60 bg-zinc-950 px-3 py-2 font-mono text-sm text-amber-100">{@raw}</code>
              <.copy_button id="copy-raw-token" value={@raw} class="shrink-0" />
            </div>
          </div>

          <div class={[card(), "mb-6 max-w-2xl"]}>
            <div class="mb-4 text-lg font-semibold">{gettext("New token")}</div>
            <form phx-submit="token_create" class="space-y-4">
              <div>
                <label class={lbl()}>
                  {gettext("Label")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <input name="label" placeholder={gettext("CI pipeline, teammate laptop...")} class={fld()} />
              </div>
              <div>
                <label class={lbl()}>{gettext("Project")}</label>
                <select name="project" phx-change="token_pick_project" class={fld()}>
                  <option value="" selected={@token_project == nil}>{gettext("Principal")}</option>
                  <option :for={c <- @projects} value={c} selected={@token_project == c}>{c}</option>
                </select>
                <p class={hlp()}>{gettext("Scopes the token to a single workspace. Principal is the default, non-project workspace.")}</p>
              </div>
              <div>
                <label class={lbl()}>
                  {gettext("Agent")} <span class="text-zinc-600">{gettext("(optional)")}</span>
                </label>
                <select name="agent" class={fld()}>
                  <option value="">{gettext("Any agent in scope")}</option>
                  <option :for={a <- agent_options(@token_project)} value={a}>{a}</option>
                </select>
                <p class={hlp()}>{gettext("Lock the token to one agent, or leave it open to any agent in the scope above.")}</p>
              </div>

              <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                <input
                  type="checkbox"
                  name="widget"
                  value="true"
                  checked={@token_widget}
                  phx-click="token_toggle_widget"
                  class="h-4 w-4 accent-orange-500"
                />
                {gettext("Public widget token (for the embeddable chat widget)")}
              </label>

              <div :if={@token_widget}>
                <label class={lbl()}>{gettext("Allowed origin")}</label>
                <input name="allowed_origin" placeholder="https://example.com" class={fld()} />
                <p class={hlp()}>{gettext("The site's origin (scheme + host). The widget's WebSocket only connects from a matching browser origin. Requires an agent above: a public token always pins to one.")}</p>
              </div>

              <div :if={!@token_widget} class="space-y-3 rounded-xl border border-zinc-800 p-3">
                <div class="text-sm font-semibold text-zinc-400">{gettext("What this token may do")}</div>

                <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                  <input type="checkbox" name="chat" value="true" checked class="h-4 w-4 accent-orange-500" />
                  {gettext("Run agents")}
                </label>

                <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                  <input
                    type="checkbox"
                    name="usage"
                    value="true"
                    checked={@token_usage}
                    phx-click="token_toggle_usage"
                    class="h-4 w-4 accent-orange-500"
                  />
                  {gettext("Read usage and billing (/v1/usage)")}
                </label>

                <div :if={@token_usage}>
                  <label class={lbl()}>{gettext("Money it may see")}</label>
                  <select name="prices" class={fld()}>
                    <option value="billable">{gettext("Billable: with the project's markup (what the client pays)")}</option>
                    <option value="list">{gettext("List: the model's price, no markup")}</option>
                    <option value="all">{gettext("Everything: adds our cost and the margin")}</option>
                  </select>
                  <p class={hlp()}>{gettext("Pick this from who holds the token. A client's token should never see cost or margin.")}</p>
                </div>

                <label :if={@token_usage} class="flex items-center gap-2 text-[15px] text-zinc-300">
                  <input type="checkbox" name="content" value="true" class="h-4 w-4 accent-orange-500" />
                  {gettext("Also show conversation content in a run's detail")}
                </label>
                <p :if={@token_usage} class={hlp()}>{gettext("Off by default: a usage report is a bill, not a transcript. On, a run's detail also returns the prompt and each tool's arguments and output.")}</p>
              </div>

              <div class="pt-1">
                <button type="submit" class={btn()}>{gettext("Generate token")}</button>
              </div>
            </form>
          </div>

          <div class="space-y-3">
            <div :for={t <- scoped_tokens(@tokens, @scope)} class={card()}>
              <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                <div class="min-w-0">
                  <span class="font-medium">{t["label"] || gettext("Unlabeled")}</span>
                  <span class="ml-2 text-sm text-zinc-500">{token_scope(t)}</span>
                </div>
                <button
                  phx-click="token_revoke"
                  phx-value-id={t["id"]}
                  data-confirm={gettext("Revoke this token? Callers using it will be locked out immediately.")}
                  class={[btn_ghost(), "text-red-400 hover:text-red-300"]}
                >
                  {gettext("Revoke")}
                </button>
              </div>
              <div :if={t["kind"] == "widget"} class="mt-1 flex items-center gap-2">
                <code class="min-w-0 flex-1 select-all truncate rounded-lg border border-zinc-800 bg-zinc-950 px-2 py-1 font-mono text-sm text-zinc-300">{t["token"]}</code>
                <.copy_button id={"copy-token-#{t["id"]}"} value={t["token"]} class="shrink-0" />
              </div>
              <div :if={t["kind"] != "widget"} class="mt-1 font-mono text-sm text-zinc-400">{t["prefix"]}</div>
              <div class="mt-0.5 text-sm text-zinc-500">{gettext("Id %{id}", id: t["id"])}</div>

              <div class="mt-2 flex flex-wrap gap-1.5">
                <span :for={badge <- permission_badges(t)} class="rounded-full border border-zinc-800 bg-zinc-950 px-2 py-0.5 text-xs text-zinc-400">
                  {badge}
                </span>
              </div>

              <details :if={t["kind"] != "widget"} class="mt-2">
                <summary class="cursor-pointer text-sm text-zinc-500 hover:text-zinc-300">{gettext("Change what it may do")}</summary>
                <form phx-submit="token_permissions" class="mt-2 space-y-2">
                  <input type="hidden" name="token_id" value={t["id"]} />

                  <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                    <input type="checkbox" name="chat" value="true" checked={permissions(t).chat} class="h-4 w-4 accent-orange-500" />
                    {gettext("Run agents")}
                  </label>

                  <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                    <input type="checkbox" name="usage" value="true" checked={permissions(t).usage} class="h-4 w-4 accent-orange-500" />
                    {gettext("Read usage and billing (/v1/usage)")}
                  </label>

                  <label class="flex items-center gap-2 text-[15px] text-zinc-300">
                    <input type="checkbox" name="content" value="true" checked={permissions(t).usage_content} class="h-4 w-4 accent-orange-500" />
                    {gettext("Also show conversation content in a run's detail")}
                  </label>

                  <select name="prices" class={fld()}>
                    <option value="billable" selected={permissions(t).prices == "billable"}>{gettext("Billable: with the project's markup (what the client pays)")}</option>
                    <option value="list" selected={permissions(t).prices == "list"}>{gettext("List: the model's price, no markup")}</option>
                    <option value="all" selected={permissions(t).prices == "all"}>{gettext("Everything: adds our cost and the margin")}</option>
                  </select>

                  <button type="submit" class={btn_ghost()}>{gettext("Save")}</button>
                </form>
              </details>
            </div>
            <p :if={scoped_tokens(@tokens, @scope) == []} class="text-[15px] text-zinc-500">
              {gettext("No tokens yet. The /v1 API is open to localhost only. Create one to require a token from every caller.")}
            </p>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("token_pick_project", %{"project" => project}, socket) do
    {:noreply, assign(socket, token_project: blank(project))}
  end

  def handle_event("token_toggle_widget", _params, socket) do
    {:noreply, assign(socket, token_widget: !socket.assigns.token_widget)}
  end

  def handle_event("token_toggle_usage", _params, socket) do
    {:noreply, assign(socket, token_usage: !socket.assigns.token_usage)}
  end

  def handle_event("token_permissions", %{"token_id" => id} = params, socket) do
    case Config.set_api_token_permissions(id, permission_opts(params)) do
      :ok ->
        {:noreply,
         socket
         |> assign(tokens: Config.api_tokens())
         |> put_flash(:info, gettext("Permissions updated."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, token_error(reason))}
    end
  end

  def handle_event("token_create", params, socket) do
    widget? = params["widget"] == "true"

    opts =
      [
        label: blank(params["label"]),
        project: blank(params["project"]),
        agent: blank(params["agent"]),
        widget: widget?,
        allowed_origin: blank(params["allowed_origin"])
      ] ++ create_permission_opts(params, widget?)

    case Config.add_api_token(opts) do
      {:ok, raw, _id} ->
        {:noreply,
         socket
         |> assign(tokens: Config.api_tokens(), raw: raw, token_widget: false, token_usage: false)
         |> put_flash(:info, gettext("Token created. Copy it now, it will not be shown again."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, token_error(reason))}
    end
  end

  def handle_event("token_revoke", %{"id" => id}, socket) do
    Config.revoke_api_token(id)
    {:noreply, assign(socket, tokens: Config.api_tokens())}
  end

  def handle_event("token_dismiss", _p, socket), do: {:noreply, assign(socket, raw: nil)}

  def handle_event("set_scope", params, socket),
    do: {:noreply, set_scope(socket, params, "/tokens")}

  def handle_event("toggle_new_project", _p, socket),
    do: {:noreply, assign(socket, new_project: !socket.assigns.new_project)}

  def handle_event("project_add", params, socket), do: {:noreply, add_project(socket, params)}

  # Agents available for the chosen scope: nil = root/Principal, else the project's agents.
  # A token carries its own project (nil = root), so scope by that directly - the
  # dashboard must only show the selected workspace's tokens, never another project's.
  defp scoped_tokens(tokens, scope), do: Enum.filter(tokens, &token_in_scope?(&1, scope))

  defp token_in_scope?(_t, "all"), do: true
  defp token_in_scope?(t, "root"), do: t["project"] in [nil, ""]
  defp token_in_scope?(t, project), do: t["project"] == project

  defp agent_options(project) do
    Config.agents_in(project) |> Enum.map(& &1.name) |> Enum.sort()
  end

  # A readable scope for a stored token: "Principal" or the project, plus the agent when
  # locked, plus a widget/origin badge when it's a public embeddable token.
  # Read fields by key rather than matching a fixed shape: a token from an older config (or a
  # hand-edit) may be missing `project`/`agent`, and a display helper must degrade, not crash the page.
  defp token_scope(t) when is_map(t) do
    base = t["project"] || gettext("Principal")
    scope = if t["agent"], do: "#{base} / #{t["agent"]}", else: base

    if t["kind"] == "widget" do
      scope <> " · " <> gettext("widget (%{origin})", origin: t["allowed_origin"] || gettext("no origin set"))
    else
      scope
    end
  end

  defp permissions(t), do: Pepe.ApiToken.permissions(t)

  # An unchecked checkbox submits nothing, so every flag is read as "present means on".
  # Both forms post all four together, which is what lets absence mean off rather than
  # "unchanged" - a half-submitted permission set is how one silently stays granted.
  #
  # Which is also why this must never be applied to a form that did not render the fields:
  # the widget form hides the whole permissions block, so reading it here would turn every
  # absent checkbox into an explicit `false` and refuse the token as good for nothing. See
  # `create_permission_opts/2`.
  defp permission_opts(params) do
    [
      chat: params["chat"] == "true",
      usage: params["usage"] == "true",
      usage_content: params["usage"] == "true" and params["content"] == "true",
      prices: params["prices"] || "billable"
    ]
  end

  # A widget token has no permissions form (it may only ever chat), so it gets no permission
  # opts at all and keeps the defaults. Otherwise the default price view is left out rather
  # than written: `Pepe.Config.add_api_token/1` only stores what differs from the default, so
  # sending it back would put a redundant `"prices": "billable"` in every entry.
  #
  # The *edit* form is different and always sends `prices` (see `token_permissions`): there,
  # omitting it would mean "leave it as it was", and a token narrowed from `all` to
  # `billable` would silently keep seeing the margin.
  defp create_permission_opts(_params, true = _widget?), do: []

  defp create_permission_opts(params, _widget?) do
    opts = permission_opts(params)
    if opts[:prices] == "billable", do: Keyword.delete(opts, :prices), else: opts
  end

  # What a token can do, at a glance, in the order it matters: what it may run, what it may
  # read, and how much of the money that read shows.
  defp permission_badges(t) do
    p = permissions(t)

    []
    |> then(&if p.chat, do: &1 ++ [gettext("chat")], else: &1)
    |> then(&if p.usage, do: &1 ++ [gettext("usage"), price_badge(p.prices)], else: &1)
    |> then(&if p.usage_content, do: &1 ++ [gettext("content")], else: &1)
  end

  defp price_badge("all"), do: gettext("cost + margin")
  defp price_badge("list"), do: gettext("no markup")
  defp price_badge(_billable), do: gettext("billable")

  defp token_error(:unknown_project), do: gettext("That project does not exist.")
  defp token_error(:agent_out_of_scope), do: gettext("That agent is not in the chosen project.")
  defp token_error(:unknown_agent), do: gettext("That agent does not exist.")

  defp token_error(:widget_needs_agent),
    do: gettext("A public widget token must be locked to one agent. Pick one above.")

  defp token_error(:widget_cannot_read_usage),
    do: gettext("A widget token sits in public page source, so it can never read usage.")

  defp token_error(:no_permissions),
    do: gettext("That leaves the token able to do nothing: keep \"Run agents\" or add \"Read usage\".")

  defp token_error(:content_needs_usage),
    do: gettext("Conversation content only means something together with \"Read usage\".")

  defp token_error(:not_found), do: gettext("That token no longer exists.")
end
