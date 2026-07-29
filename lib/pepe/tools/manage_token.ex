defmodule Pepe.Tools.ManageToken do
  @moduledoc """
  Let an agent mint, list, and revoke **API tokens** from a conversation, so a human
  can hand out `/v1` access ("give the Chatwoot integration a token for the buskaza
  project") without dropping to a terminal.

  Deliberately guarded, because a token grants API access:

    * **In the agent's tool allowlist** - that's the on/off. Give it only to a trusted
      owner-style agent, never to a client-facing bot.
    * **Not read-only, so it is permission-gated** - each call goes through the human
      authorize step (unless pre-approved), which is the confirmation before a token is
      minted or revoked.
    * **The secret is shown once** - `create` returns the raw `pepe_...` token a single
      time (only its hash is stored), so it lands in the reply for the user to copy and
      is never retrievable again. A **widget** token is the exception: it sits in
      public page source anyway, so its raw value stays retrievable via `list` (and
      editable via `update`), instead of forcing a rotation the moment a copy is lost.

  Minting the first token also flips the API from "loopback only" to "token required",
  so a remote caller can then reach it. `list` and `revoke` never expose a regular
  token's secret, only a short fingerprint.

  A token's **permissions** (`chat`, `usage`, `prices`, `usage_content` - see
  `Pepe.ApiToken`) are settable here too, on `create` and afterwards via `permissions`.
  They default to today's behaviour, so an agent that has always minted chat tokens keeps
  minting exactly those; a read-only billing token for a client is
  `chat: false, usage: true, prices: "billable"`.

  Actions: `create`, `list`, `revoke`, `permissions`, `update` (widget appearance only).
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "manage_token"

  @impl true
  def spec do
    function(
      "manage_token",
      """
      Mint, list, revoke and (widget-only) update API tokens for the /v1 HTTP API. A \
      token grants API access, so confirm the scope with the user before you create \
      one. A regular token's raw value is shown exactly once in the result and can't \
      be retrieved again; a widget token's stays retrievable (it sits in public page \
      source anyway) and its appearance stays editable.

      actions:
      - create: mint a token. Optional `project` (omit for the root/Principal scope), \
        optional `agent` (a full handle like "buskaza/default" to lock the token to one \
        agent; must be inside `project`), optional `label` (a human note). A project \
        token reaches only that project's agents; an agent token always runs that agent \
        and ignores the request's model field. Pass `widget: true` for a token meant to \
        sit in public page source (an embedded chat widget's script tag) - it then \
        REQUIRES `agent` (a public credential always pins to one agent) and should \
        carry `allowed_origin` (the site's scheme+host, e.g. "https://example.com"); \
        a browser connecting with this token is refused unless its real Origin header \
        matches that value. Optional \
        appearance for a widget token - `title`, `logo` (an image URL), `color` (hex), \
        `theme` ("dark" or "light"), `greeting`, `position` ("left" or "right") - fetched \
        by the widget script at load time, so it never needs to be baked into the site's \
        embed snippet.
        A token may run agents and may NOT read usage unless told otherwise. Pass \
        `chat: false` for a token that may only read, `usage: true` to let it read \
        /v1/usage, `prices` for how much money that read shows ("billable" = with the \
        project's markup, what the client pays, the default; "list" = no markup; "all" \
        = adds our cost and margin, only for a token the operator keeps), and \
        `usage_content: true` to let a run's detail include the prompt and tool \
        arguments/output. A client's billing token is `chat: false, usage: true`; never \
        give a client "all" or `usage_content`. A widget token can never read usage.
      - list: show existing tokens (label, scope, permissions, id; a widget token's full \
        value, a regular token's safe fingerprint only).
      - revoke: delete a token - needs `id` (from `list`).
      - permissions: change what an existing token may do, in place - needs `id`, plus \
        whichever of `chat`/`usage`/`prices`/`usage_content` should change (omitted ones \
        are left as they are). Never touches the secret, so a client's integration keeps \
        working while what it may see changes.
      - update: change a **widget** token's appearance in place - needs `id`, plus \
        whichever of `title`/`logo`/`color`/`theme`/`greeting`/`position` should \
        change (omitted ones are left as they are). Never touches the token's secret, \
        agent, or allowed_origin - those are rotate-only (create a new one, revoke the \
        old).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(create list revoke permissions update),
            "description" => "What to do."
          },
          "chat" => %{
            "type" => "boolean",
            "description" => "For create/permissions: may this token run agents? Defaults to true."
          },
          "usage" => %{
            "type" => "boolean",
            "description" => "For create/permissions: may this token read /v1/usage? Defaults to false."
          },
          "prices" => %{
            "type" => "string",
            "enum" => ~w(billable list all),
            "description" =>
              "For create/permissions: how much money a usage read shows. \"billable\" (with markup, the default), \"list\" (no markup), \"all\" (adds cost and margin - operator only)."
          },
          "usage_content" => %{
            "type" => "boolean",
            "description" =>
              "For create/permissions: may a run's detail include conversation content (prompt, tool arguments/output)? Defaults to false."
          },
          "project" => %{
            "type" => "string",
            "description" => "For create: the project handle to scope to. Omit for the root/Principal scope."
          },
          "agent" => %{
            "type" => "string",
            "description" => "For create: a full agent handle to lock the token to, e.g. \"buskaza/default\". Required when widget is true."
          },
          "label" => %{
            "type" => "string",
            "description" => "For create: a human-readable note, e.g. \"chatwoot prod\"."
          },
          "widget" => %{
            "type" => "boolean",
            "description" => "For create: mint a public, embeddable widget token (requires `agent`)."
          },
          "allowed_origin" => %{
            "type" => "string",
            "description" => "For create with widget: the site's origin, e.g. \"https://example.com\"."
          },
          "title" => %{"type" => "string", "description" => "For create/update with widget: the chat panel's header text."},
          "logo" => %{
            "type" => "string",
            "description" => "For create/update with widget: a small square image URL for the bubble/header icon."
          },
          "color" => %{"type" => "string", "description" => "For create/update with widget: accent color, e.g. \"#ea580c\"."},
          "theme" => %{
            "type" => "string",
            "enum" => ~w(dark light),
            "description" => "For create/update with widget: the panel's base color scheme."
          },
          "greeting" => %{"type" => "string", "description" => "For create/update with widget: the first message shown to a visitor."},
          "position" => %{
            "type" => "string",
            "enum" => ~w(left right),
            "description" => "For create/update with widget: which corner the bubble sits in."
          },
          "id" => %{"type" => "string", "description" => "For revoke/permissions/update: the token id from list."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_token needs an `action`"}

  defp dispatch("create", args), do: create(args)
  defp dispatch("list", _args), do: {:ok, render_list(Config.api_tokens())}
  defp dispatch("revoke", args), do: revoke(args)
  defp dispatch("permissions", args), do: permissions(args)
  defp dispatch("update", args), do: update(args)
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  @appearance_keys ~w(title logo color theme greeting position)

  defp create(args) do
    opts =
      [
        project: blank_to_nil(args["project"]),
        agent: blank_to_nil(args["agent"]),
        label: blank_to_nil(args["label"]),
        widget: args["widget"] == true,
        allowed_origin: blank_to_nil(args["allowed_origin"])
      ] ++ appearance_opts(args)

    case permission_opts(args) do
      {:error, message} -> {:error, message}
      {:ok, perms} -> create_token(opts ++ perms)
    end
  end

  defp create_token(opts) do
    case Config.add_api_token(opts) do
      {:ok, raw, id} -> {:ok, created_message(raw, id, opts)}
      {:error, :widget_needs_agent} -> {:error, "a widget token must be agent-locked; pass `agent`"}
      {:error, :unknown_project} -> {:error, "no project named #{inspect(opts[:project])}"}
      {:error, :unknown_agent} -> {:error, "no agent named #{inspect(opts[:agent])}"}
      {:error, :agent_out_of_scope} -> {:error, "agent #{opts[:agent]} is not in project #{opts[:project]}"}
      {:error, reason} -> {:error, permission_error(reason)}
    end
  end

  defp permissions(args) do
    with id when is_binary(id) <- blank_to_nil(args["id"]),
         {:ok, [_ | _] = opts} <- permission_opts(args) do
      case Config.set_api_token_permissions(id, opts) do
        :ok -> {:ok, "Token #{id} permissions updated: #{permission_text(Config.api_tokens(), id)}"}
        {:error, :not_found} -> {:error, "no token with id #{id}"}
        {:error, reason} -> {:error, permission_error(reason)}
      end
    else
      nil -> {:error, "permissions needs an `id` (see list)"}
      {:ok, []} -> {:error, "permissions needs at least one of chat/usage/prices/usage_content"}
      {:error, message} -> {:error, message}
    end
  end

  # Only the keys actually passed, so an unmentioned permission stays as it is rather than
  # being reset to its default by every call that did not think to repeat it.
  #
  # A bad value is refused rather than coerced. Everything downstream is fail-closed - a
  # non-boolean reads as `false`, an unknown price view narrows to `"billable"` - so a model
  # that sends the string `"true"` would *revoke* the permission it was asking to grant, tell
  # nobody, and report success. Silence is the wrong answer when the caller is an LLM.
  defp permission_opts(args) do
    Enum.reduce_while(~w(chat usage usage_content prices), {:ok, []}, fn key, {:ok, acc} ->
      case permission_value(key, args) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, acc ++ [{String.to_existing_atom(key), value}]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp permission_value(key, args) do
    cond do
      not Map.has_key?(args, key) -> :absent
      key == "prices" -> price_value(args[key])
      is_boolean(args[key]) -> {:ok, args[key]}
      true -> {:error, "#{key} must be true or false, got #{inspect(args[key])}"}
    end
  end

  defp price_value(value) do
    if value in Pepe.ApiToken.price_views(),
      do: {:ok, value},
      else: {:error, "prices must be one of #{Enum.join(Pepe.ApiToken.price_views(), ", ")}, got #{inspect(value)}"}
  end

  defp permission_error(:widget_cannot_read_usage),
    do: "a widget token sits in public page source - it can never read usage"

  defp permission_error(:no_permissions),
    do: "that leaves the token able to do nothing - keep chat, or add usage"

  defp permission_error(:content_needs_usage),
    do: "usage_content only means something together with usage: true"

  defp revoke(args) do
    case blank_to_nil(args["id"]) do
      nil ->
        {:error, "revoke needs an `id` (see list)"}

      id ->
        case Config.revoke_api_token(id) do
          :ok -> {:ok, "Token #{id} revoked."}
          {:error, :not_found} -> {:error, "no token with id #{id}"}
        end
    end
  end

  defp update(args) do
    case blank_to_nil(args["id"]) do
      nil ->
        {:error, "update needs an `id` (see list)"}

      id ->
        case Config.update_widget_token(id, appearance_opts(args)) do
          :ok -> {:ok, "Widget token #{id} updated."}
          {:error, :not_found} -> {:error, "no token with id #{id}"}
          {:error, :not_widget} -> {:error, "token #{id} isn't a widget token - only a widget's appearance can be updated"}
        end
    end
  end

  defp appearance_opts(args) do
    for key <- @appearance_keys, Map.has_key?(args, key), do: {String.to_existing_atom(key), blank_to_nil(args[key])}
  end

  ###
  ### rendering
  ###

  defp created_message(raw, id, opts) do
    kind = if opts[:widget], do: " (widget, origin: #{opts[:allowed_origin] || "not set"})", else: ""

    retrievable =
      if opts[:widget], do: " list shows it again any time, since it's a widget token.", else: " Copy it now - it will not be shown again."

    """
    API token created (id #{id}, scope: #{scope_text(opts[:project], opts[:agent])}#{kind}).#{retrievable}

        #{raw}

    Present it as "Authorization: Bearer #{raw}". Creating a token locks the API, so
    remote callers now need a token (local loopback calls still work without one).
    """
  end

  defp render_list([]), do: "No API tokens. The /v1 API is open to loopback only."

  defp render_list(tokens) do
    "API tokens:\n\n" <>
      Enum.map_join(tokens, "\n", fn t ->
        note = if t["label"], do: " - #{t["label"]}", else: ""
        kind = if t["kind"] == "widget", do: " (widget, #{t["allowed_origin"] || "no origin set"})", else: ""
        # A widget token's raw value is retrievable (it sits in public page source
        # anyway - see Config.add_api_token/1); a regular token only ever shows its
        # safe fingerprint prefix, since its raw value was never stored.
        shown = if t["kind"] == "widget", do: t["token"], else: t["prefix"]
        "• #{t["id"]} [#{scope_text(t["project"], t["agent"])}]#{kind} {#{permission_label(t)}} #{shown}#{note}"
      end)
  end

  defp permission_text(tokens, id) do
    case Enum.find(tokens, &(&1["id"] == id)) do
      nil -> "unknown"
      token -> permission_label(token)
    end
  end

  defp permission_label(token) do
    p = Pepe.ApiToken.permissions(token)
    granted = for {name, on?} <- [chat: p.chat, usage: p.usage, content: p.usage_content], on?, do: to_string(name)

    Enum.join(granted ++ if(p.usage, do: [p.prices], else: []), ", ")
  end

  defp scope_text(nil, nil), do: "Principal (root)"
  defp scope_text(project, nil), do: "project #{project}"
  defp scope_text(_project, agent), do: "agent #{agent}"

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_to_nil(v), do: v
end
