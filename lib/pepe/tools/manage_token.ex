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
      is never retrievable again.

  Minting the first token also flips the API from "loopback only" to "token required",
  so a remote caller can then reach it. `list` and `revoke` never expose the secret,
  only a short fingerprint.

  Actions: `create`, `list`, `revoke`.
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
      Mint, list and revoke API tokens for the /v1 HTTP API. A token grants API access, \
      so confirm the scope with the user before you create one. The raw token is shown \
      exactly once in the result; tell the user to copy it, because it can't be shown \
      again.

      actions:
      - create: mint a token. Optional `company` (omit for the root/Principal scope), \
        optional `agent` (a full handle like "buskaza/default" to lock the token to one \
        agent; must be inside `company`), optional `label` (a human note). A company \
        token reaches only that company's agents; an agent token always runs that agent \
        and ignores the request's model field. Pass `widget: true` for a token meant to \
        sit in public page source (an embedded chat widget's script tag) - it then \
        REQUIRES `agent` (a public credential always pins to one agent) and should \
        carry `allowed_origin` (the site's scheme+host, e.g. "https://example.com"); \
        the WebSocket only accepts that widget from a matching browser origin.
      - list: show existing tokens (label, scope, fingerprint, id). Never shows the secret.
      - revoke: delete a token - needs `id` (from `list`).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(create list revoke),
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
          "id" => %{"type" => "string", "description" => "For revoke: the token id from list."}
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
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  defp create(args) do
    opts = [
      company: blank_to_nil(args["company"]),
      agent: blank_to_nil(args["agent"]),
      label: blank_to_nil(args["label"]),
      widget: args["widget"] == true,
      allowed_origin: blank_to_nil(args["allowed_origin"])
    ]

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

  ###
  ### rendering
  ###

  defp created_message(raw, id, opts) do
    kind = if opts[:widget], do: " (widget, origin: #{opts[:allowed_origin] || "not set"})", else: ""

    """
    API token created (id #{id}, scope: #{scope_text(opts[:company], opts[:agent])}#{kind}).

    Copy it now, it will not be shown again:

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
        "• #{t["id"]} [#{scope_text(t["company"], t["agent"])}]#{kind} #{t["prefix"]}#{note}"
      end)
  end

  defp scope_text(nil, nil), do: "Principal (root)"
  defp scope_text(company, nil), do: "company #{company}"
  defp scope_text(_company, agent), do: "agent #{agent}"

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_to_nil(v), do: v
end
