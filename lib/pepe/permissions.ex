defmodule Pepe.Permissions do
  @moduledoc """
  The permission gate for tool calls - Pepe's "ask before doing something risky".

  Read-only tools (`@always_safe`) run freely. Everything else - running code,
  writing/moving files, changing config, and *any* plugin tool (unknown ⇒ treated
  as risky) - must be authorized. When a risky tool hasn't been pre-approved, the
  runtime asks the user through an **`authorize` callback supplied by the surface**
  (`ctx.authorize`), so each gateway renders the prompt in its own native format
  (Telegram inline buttons, the CLI's arrow-key menu, ...). The core only defines the
  decision contract and remembers the answer.

  A decision is one of:

    * `:once`    - allow just this call; ask again next time.
    * `:session` - allow for the rest of this session (kept in-memory; forgotten on
      `/new` and on restart) - other sessions ask again.
    * `:always`  - allow from now on; persisted on the agent in `config.json`.
    * `:deny`    - refuse; never remembered, so it's asked again.

  Surfaces with no human to ask (the HTTP API) pass no `authorize` and run freely.

  ## A grant remembers what it was given for

  `:session` and `:always` are not blank cheques on a tool name. Each call is classified by
  `Pepe.Permissions.Risk` (deletes files, reaches the network, runs with elevated
  privileges, ...), and what gets remembered is the tool **and the risks the human was
  actually looking at**. Approving bash while reading `ls build/` grants bash for calls that
  flag nothing; the first `rm -rf` flags `deletes`, is not covered, and stops to ask. See
  `Pepe.Permissions.Grant`, including what this deliberately is not: a sandbox.
  """

  alias Pepe.Config
  alias Pepe.Permissions.Grant
  alias Pepe.Permissions.Risk
  alias Pepe.Permissions.SessionStore

  # Tools that don't go through the human gate: read-only ones, plus `send_to_agent`
  # (governed by the directed `can_message` route allowlist instead). Anything not
  # listed - including drop-in plugin tools - requires approval (the safe default).
  @always_safe ~w(read_file list_dir fetch_url web_search config_get skill docs doctor scan_skill send_to_agent)

  @type decision :: :once | :session | :always | :deny | {:deny, String.t()}

  @doc "Whether a tool needs authorization before it can run."
  def requires_approval?(name), do: name not in @always_safe

  @doc """
  Decide whether `name` may run for this call. Returns `:allow`, `:deny`, or
  `{:deny, reason}` when the human attached a reason - asking the user via
  `ctx.authorize` when needed and remembering the grant.
  """
  @spec gate(String.t(), term(), map()) :: :allow | :deny | {:deny, String.t()}
  def gate(name, args, ctx) do
    risks = Risk.hints(name, decode(args))

    cond do
      not requires_approval?(name) -> :allow
      preapproved?(name, risks, ctx) -> :allow
      true -> ask(name, args, risks, ctx)
    end
  end

  defp decode(args) when is_map(args), do: args

  defp decode(args) do
    case Jason.decode(to_string(args)) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "The message handed back to the model when a tool call was refused."
  def denied_message(name, reason \\ nil)

  def denied_message(name, nil) do
    "Error: the user did not authorize running `#{name}`. Do not retry it - " <>
      "consider a different approach or ask the user what to do instead."
  end

  def denied_message(name, reason) when is_binary(reason) do
    "Error: the user did not authorize running `#{name}` (reason: #{reason}). Do not retry it - " <>
      "consider a different approach or ask the user what to do instead."
  end

  # Pre-approved either persistently (on the agent) or for this session - and approved for
  # *this* call, not merely for a tool of the same name (see Pepe.Permissions.Grant).
  defp preapproved?(name, risks, ctx),
    do: persistent?(name, risks, ctx) or session?(name, risks, ctx)

  defp persistent?(name, risks, %{agent: %{auto_approve: list}}) when is_list(list),
    do: Grant.covers?(list, name, risks)

  defp persistent?(_name, _risks, _ctx), do: false

  defp session?(name, risks, %{session_key: key}) when is_binary(key),
    do: Grant.covers?(SessionStore.grants(key), name, risks)

  defp session?(_name, _risks, _ctx), do: false

  # The surface renders the question. `:risks` rides along in the ctx so it can say what the
  # human is about to sign for, rather than leaving each surface to work it out again.
  defp ask(name, args, risks, ctx) do
    case ctx[:authorize] do
      fun when is_function(fun, 3) ->
        fun.(name, args, Map.put(ctx, :risks, risks))
        |> remember(name, risks, ctx)
        |> to_allow()

      _ ->
        # No interactive channel to ask through (e.g. the HTTP API): keep working.
        :allow
    end
  end

  # Persist an `:always` grant on the agent, and also grant it for the current
  # session right away: `ctx.agent` is a snapshot taken at the start of this run
  # and never refreshed mid-loop, so without this a second risky call later in
  # the very same turn would still see the old auto_approve list and re-prompt -
  # the persisted grant would only actually take effect on the *next* turn.
  defp remember(:always, name, risks, %{agent: %{name: agent_name}} = ctx) when is_binary(agent_name) do
    grant = Grant.for(name, risks)
    Config.allow_tool(agent_name, grant)
    if key = ctx[:session_key], do: SessionStore.allow(key, grant)
    :always
  end

  defp remember(:session, name, risks, %{session_key: key}) when is_binary(key) do
    SessionStore.allow(key, Grant.for(name, risks))
    :session
  end

  defp remember(decision, _name, _risks, _ctx), do: decision

  defp to_allow(:deny), do: :deny
  defp to_allow({:deny, reason}) when is_binary(reason), do: {:deny, reason}
  defp to_allow(_grant), do: :allow
end
