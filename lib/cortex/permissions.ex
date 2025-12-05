defmodule Cortex.Permissions do
  @moduledoc """
  The permission gate for tool calls — Cortex's "ask before doing something risky".

  Read-only tools (`@always_safe`) run freely. Everything else — running code,
  writing/moving files, changing config, and *any* plugin tool (unknown ⇒ treated
  as risky) — must be authorized. When a risky tool hasn't been pre-approved, the
  runtime asks the user through an **`authorize` callback supplied by the surface**
  (`ctx.authorize`), so each gateway renders the prompt in its own native format
  (Telegram inline buttons, the CLI's arrow-key menu, …). The core only defines the
  decision contract and remembers the answer.

  A decision is one of:

    * `:once`    — allow just this call; ask again next time.
    * `:session` — allow for the rest of this session (kept in-memory; forgotten on
      `/new` and on restart) — other sessions ask again.
    * `:always`  — allow from now on; persisted on the agent in `config.json`.
    * `:deny`    — refuse; never remembered, so it's asked again.

  Surfaces with no human to ask (the HTTP API) pass no `authorize` and run freely.
  """

  alias Cortex.Config
  alias Cortex.Permissions.SessionStore

  # Read-only tools that never need approval. Anything not listed — including
  # drop-in plugin tools — requires it (the safe default for unknown tools).
  @always_safe ~w(read_file list_dir fetch_url web_search config_get skill)

  @type decision :: :once | :session | :always | :deny

  @doc "Whether a tool needs authorization before it can run."
  def requires_approval?(name), do: name not in @always_safe

  @doc """
  Decide whether `name` may run for this call. Returns `:allow` or `:deny`,
  asking the user via `ctx.authorize` when needed and remembering the grant.
  """
  @spec gate(String.t(), term(), map()) :: :allow | :deny
  def gate(name, args, ctx) do
    cond do
      not requires_approval?(name) -> :allow
      preapproved?(name, ctx) -> :allow
      true -> ask(name, args, ctx)
    end
  end

  @doc "The message handed back to the model when a tool call was refused."
  def denied_message(name) do
    "Error: the user did not authorize running `#{name}`. Do not retry it — " <>
      "consider a different approach or ask the user what to do instead."
  end

  # Pre-approved either persistently (on the agent) or for this session.
  defp preapproved?(name, ctx), do: persistent?(name, ctx) or session?(name, ctx)

  defp persistent?(name, %{agent: %{auto_approve: list}}) when is_list(list), do: name in list
  defp persistent?(_name, _ctx), do: false

  defp session?(name, %{session_key: key}) when is_binary(key),
    do: SessionStore.member?(key, name)

  defp session?(_name, _ctx), do: false

  defp ask(name, args, ctx) do
    case ctx[:authorize] do
      fun when is_function(fun, 3) ->
        fun.(name, args, ctx) |> remember(name, ctx) |> to_allow()

      _ ->
        # No interactive channel to ask through (e.g. the HTTP API): keep working.
        :allow
    end
  end

  # Persist an `:always` grant on the agent; keep a `:session` grant in memory.
  defp remember(:always, name, %{agent: %{name: agent_name}}) when is_binary(agent_name) do
    Config.allow_tool(agent_name, name)
    :always
  end

  defp remember(:session, name, %{session_key: key}) when is_binary(key) do
    SessionStore.allow(key, name)
    :session
  end

  defp remember(decision, _name, _ctx), do: decision

  defp to_allow(:deny), do: :deny
  defp to_allow(_grant), do: :allow
end
