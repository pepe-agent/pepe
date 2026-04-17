defmodule Pepe.Tools.ManageToken do
  @moduledoc """
  Let an agent mint, list, and revoke **API tokens** from a conversation, so a human
  can hand out `/v1` access ("give the Chatwoot integration a token for the buskaza
  company") without dropping to a terminal.

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

  Actions: `create`, `list`, `revoke`, `update` (widget appearance only).
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
      - create: mint a token. Optional `company` (omit for the root/Principal scope), \
        optional `agent` (a full handle like "buskaza/default" to lock the token to one \
        agent; must be inside `company`), optional `label` (a human note). A company \
        token reaches only that company's agents; an agent token always runs that agent \
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
      - list: show existing tokens (label, scope, id; a widget token's full value, a \
        regular token's safe fingerprint only).
      - revoke: delete a token - needs `id` (from `list`).
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
            "enum" => ~w(create list revoke update),
            "description" => "What to do."
          },
          "company" => %{
            "type" => "string",
            "description" => "For create: the company handle to scope to. Omit for the root/Principal scope."
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
          "id" => %{"type" => "string", "description" => "For revoke/update: the token id from list."}
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
  defp dispatch("update", args), do: update(args)
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  @appearance_keys ~w(title logo color theme greeting position)

  defp create(args) do
    opts =
      [
        company: blank_to_nil(args["company"]),
        agent: blank_to_nil(args["agent"]),
        label: blank_to_nil(args["label"]),
        widget: args["widget"] == true,
        allowed_origin: blank_to_nil(args["allowed_origin"])
      ] ++ appearance_opts(args)

    case Config.add_api_token(opts) do
      {:ok, raw, id} -> {:ok, created_message(raw, id, opts)}
      {:error, :widget_needs_agent} -> {:error, "a widget token must be agent-locked; pass `agent`"}
      {:error, :unknown_company} -> {:error, "no company named #{inspect(opts[:company])}"}
      {:error, :unknown_agent} -> {:error, "no agent named #{inspect(opts[:agent])}"}
      {:error, :agent_out_of_scope} -> {:error, "agent #{opts[:agent]} is not in company #{opts[:company]}"}
    end
  end

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
    API token created (id #{id}, scope: #{scope_text(opts[:company], opts[:agent])}#{kind}).#{retrievable}

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
        "• #{t["id"]} [#{scope_text(t["company"], t["agent"])}]#{kind} #{shown}#{note}"
      end)
  end

  defp scope_text(nil, nil), do: "Principal (root)"
  defp scope_text(company, nil), do: "company #{company}"
  defp scope_text(_company, agent), do: "agent #{agent}"

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_to_nil(v), do: v
end
