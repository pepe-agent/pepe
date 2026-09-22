defmodule Pepe.Webhooks do
  @moduledoc """
  Inbound-webhook gateway - the WhatsApp-and-friends counterpart to the Telegram
  poller. A single route `/webhooks/:project/:provider/:slug` (see
  `PepeWeb.WebhookController`) dispatches here; each connection binds to an agent
  and runs it on a session keyed `provider:agent:from`.

  A connection is a config entry (`Pepe.Config` `"webhooks"`, keyed by its unique
  `slug`) with a `mode`:

    * `admin`   - like a Telegram owner bot: slash commands on, restricted to your
      own numbers (`allowed_numbers`), a trainer conversation.
    * `support` - customer-facing: slash commands off, open to anyone, never learns
      (`trainers: []`), and best paired with a locked-down agent (safe tools only,
      since there's no human to approve risky ones) and an ephemeral session TTL.

  `/model`/`/models` (admin connections only) go through `Pepe.ModelSwitch`: a
  `trainers` member may change the model globally or just for their own
  conversation; anyone else may only change their own. Set `model_switch_locked`
  on the entry to keep non-trainers from touching it at all.
  """

  use Gettext, backend: Pepe.Gettext

  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Project
  alias Pepe.Config
  alias Pepe.ModelSwitch

  @builtin_providers %{
    "whatsapp" => Pepe.Webhooks.WhatsApp,
    "slack" => Pepe.Webhooks.Slack,
    "discord" => Pepe.Webhooks.Discord,
    "msteams" => Pepe.Webhooks.MsTeams,
    "googlechat" => Pepe.Webhooks.GoogleChat
  }

  @doc "The provider module for a name (built-in or plugin), or nil."
  def provider(name), do: Map.get(registry(), name)

  @doc "Known provider names (built-in plus installed plugins), sorted."
  def providers, do: registry() |> Map.keys() |> Enum.sort()

  @doc "Whether a provider name is one of the native, built-in channels."
  def builtin?(name), do: Map.has_key?(@builtin_providers, name)

  @doc """
  The `%{name => module}` map of every provider. `Map.merge/2` gives precedence to its
  second argument on a key clash, so a plugin provider wins over a built-in of the same
  name - the opposite rule from `Pepe.Tools`, and the deliberate way to replace a bundled
  provider with your own version of it.
  """
  def registry, do: Map.merge(@builtin_providers, plugin_providers())

  @doc """
  Send `blocks` (see `Pepe.Presentation`) to `to` through provider `mod`'s own
  `deliver_blocks/3` when it implements one, else flattened to plain text
  (`Pepe.Presentation.to_text/1`) through its ordinary `deliver/3`.
  """
  # No tighter a spec than term(): mod is a runtime-resolved plugin/provider module, so -
  # same as deliver_file/4's own callers - dialyzer (correctly) can't guarantee the
  # callback's own declared :ok | {:error, term()} actually holds. Callers still guard
  # against anything else at runtime (see e.g. Pepe.Tools.SendPresentation's normalize/1).
  @spec deliver_blocks(module(), map(), String.t(), [Pepe.Presentation.block()]) :: term()
  def deliver_blocks(mod, entry, to, blocks) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :deliver_blocks, 3) do
      mod.deliver_blocks(entry, to, blocks)
    else
      mod.deliver(entry, to, Pepe.Presentation.to_text(blocks))
    end
  end

  # A plugin provider is any plugin module exporting `name/0` plus the Provider callbacks.
  defp plugin_providers do
    [{:name, 0}, {:verify, 2}, {:authenticate, 3}, {:parse, 1}, {:deliver, 3}]
    |> Pepe.Plugins.implementing()
    |> Enum.flat_map(fn mod ->
      case Pepe.Plugins.safe_call(mod, :name, []) do
        {:ok, name} when is_binary(name) -> [{name, mod}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  Resolve a connection by its `(project, provider, slug)` path. The `slug` is the
  unique key; `project` and `provider` from the path are validated against the
  stored entry so a mismatched URL can't reach it. `\"root\"` in the path means the
  no-project scope. Returns the entry (with its slug) or `nil`.
  """
  def resolve(project, provider, slug) do
    with entry when is_map(entry) <- Config.get_webhook(slug),
         true <- entry["provider"] == provider,
         true <- norm(entry["project"]) == norm(project) do
      Map.put(entry, "slug", slug)
    else
      _ -> nil
    end
  end

  @doc "Answer a provider's verification handshake for this connection."
  def verify(project, provider, slug, params) do
    with entry when is_map(entry) <- resolve(project, provider, slug),
         mod when not is_nil(mod) <- provider(provider) do
      mod.verify(entry, params)
    else
      _ -> :error
    end
  end

  @doc """
  Handle an inbound event: authenticate it, parse out messages, and for each run
  the bound agent and deliver the reply. Runs the agent work asynchronously so the
  provider gets its `200` immediately (Meta retries slow webhooks). Returns `:ok`
  once accepted, or `{:error, reason}` when the connection/signature is bad.
  """
  def handle_inbound(project, provider, slug, raw_body, payload, headers) do
    with entry when is_map(entry) <- resolve(project, provider, slug),
         mod when not is_nil(mod) <- provider(provider),
         :ok <- mod.authenticate(entry, raw_body, headers) do
      case sync_respond(mod, entry, payload, headers) do
        {:reply, status, content_type, body} ->
          {:respond, status, content_type, body}

        {:reply_async, status, content_type, body} ->
          run_parse(mod, entry, payload)
          {:respond, status, content_type, body}

        :cont ->
          run_parse(mod, entry, payload)
          :ok
      end
    else
      :error -> {:error, :unauthorized}
      _ -> {:error, :unknown_connection}
    end
  end

  # A provider whose protocol needs a synchronous answer to the POST (Slack's challenge,
  # Discord's PING/ack) implements `respond/3`; others fall through to the async flow.
  defp sync_respond(mod, entry, payload, headers) do
    if function_exported?(mod, :respond, 3), do: mod.respond(entry, payload, headers), else: :cont
  end

  # Parses first (pure, no side effects in any provider today), THEN gates each
  # parsed message - addressed?/2 needs the raw payload, but the per-conversation
  # mention waiver (mention_waived?/2) needs `from`, which only parse/1 knows how
  # to extract, so the gate can't run before parsing the way it used to.
  defp run_parse(mod, entry, payload) do
    case mod.parse(payload) do
      {:ok, messages} -> Enum.each(messages, &maybe_dispatch(mod, entry, payload, &1))
      :ignore -> :ok
    end
  end

  defp maybe_dispatch(mod, entry, payload, %{from: from} = message) do
    if addressed?(mod, entry, payload) or mention_waived?(entry, from) do
      dispatch(entry, mod, message)
    else
      :ok
    end
  end

  # A provider that implements `addressed?/2` gates on it (mention-in-group / DM
  # rules); one that hasn't added gating yet is always addressed (today's behavior).
  defp addressed?(mod, entry, payload) do
    if function_exported?(mod, :addressed?, 2), do: mod.addressed?(entry, payload), else: true
  end

  # A per-conversation waiver of the addressed?/2 gate above (see the `/mention`
  # command in dispatch_command/4) - lives on the session, not the connection, so
  # toggling it in one channel/DM never affects any other, and a fresh conversation
  # (`/new`) forgets it, same as Telegram's own `/mention`.
  defp mention_waived?(entry, from) do
    key = session_key(entry, from)
    SessionSupervisor.ensure(key, entry["agent"], session_opts(entry))
    Session.mention_optional?(key)
  end

  @doc false
  def session_key(entry, from), do: "#{entry["provider"]}:#{entry["agent"]}:#{from}"

  # Run one inbound message through the bound agent, off the request process.
  #
  # Messages of one conversation go through one lane (Pepe.Webhooks.Lane), in the order they
  # were received: an attachment is resolved to text first (Pepe.Webhooks.Media), inside a
  # task rather than in parse/1 because it costs a download and a transcription that do not
  # belong on the request the provider is waiting on, and a slow voice note must not let the
  # text message sent after it reach the agent first. It happens *before* command/3 so a
  # `/new` said out loud still reads as a command - the whole point of resolving media at the
  # door. Different conversations never wait for each other.
  defp dispatch(entry, mod, %{from: from} = message) do
    cond do
      not allowed?(entry, actor(message)) ->
        Logger.info("[webhooks] #{entry["slug"]}: ignored message from disallowed #{actor(message)}")

      Pepe.Webhooks.Dedup.seen?(entry["slug"], message[:id]) ->
        Logger.debug("[webhooks] #{entry["slug"]}: skipping duplicate delivery of #{message[:id]}")

      true ->
        job = %{entry: entry, mod: mod, message: message, callers: [self() | Process.get(:"$callers", [])]}

        case Pepe.Webhooks.Lane.submit(session_key(entry, from), job) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[webhooks] #{entry["slug"]}: dropped a message from #{from}: #{inspect(reason)}")
            reply_async(mod, entry, from, dgettext("webhooks", "I'm a bit behind on messages here. Could you send that again in a moment?"))
        end
    end

    :ok
  end

  # Who is speaking, as opposed to where the conversation lives: on a channel where many
  # people share one conversation (a Discord server channel) the allowlist and the trainer
  # rules are about the person, while `from` names the place the reply goes.
  defp actor(message), do: message[:sender_id] || message.from

  @doc """
  Feed one event that arrived over a persistent connection (Discord's gateway) through the
  same parse, gate and dispatch as a webhook `POST`, minus the signature check: the socket was
  authenticated with the bot's own token when it was opened, and there is no request to
  authenticate. `slug` names the connection.
  """
  @spec handle_gateway_event(String.t(), map()) :: :ok | {:error, :unknown_connection}
  def handle_gateway_event(slug, payload) do
    with entry when is_map(entry) <- Config.get_webhook(slug),
         mod when not is_nil(mod) <- provider(entry["provider"]) do
      run_parse(mod, Map.put(entry, "slug", slug), payload)
    else
      _ -> {:error, :unknown_connection}
    end
  end

  @doc false
  # First half of a job, run in a task off the lane: what the agent should be given for this
  # message, or `:ignore` when there is nothing to answer.
  @spec prepare(map()) :: {:ok, String.t(), keyword()} | :ignore
  def prepare(%{entry: entry, mod: mod, message: message}) do
    if over_message_limit?(entry) do
      # A voice note or a document is a download plus a transcription - real cost -
      # and start_turn/4 refuses this message on message-limit grounds regardless of
      # what it resolves to, so nothing here is worth spending that on. Whether it's
      # actually refused is still decided exactly once, inside the session itself;
      # this only skips paying for media a refusal would never use.
      {:ok, message[:text] || "", []}
    else
      # Nothing to answer means the sender has already been told why.
      Pepe.Webhooks.Media.resolve(mod, entry, message)
    end
  end

  # Same "does this message count against the cap" rule Pepe.Agent.Session applies for
  # real (agent.exempt_message_limit) - called here too only to short-circuit before a
  # costly media fetch, never as a second place the actual decision is made. The other
  # half of Session's own rule (not one of Pepe's internal surfaces - tui/web/api/acp)
  # is skipped: every webhook session key is "provider:agent:from", never one of those.
  defp over_message_limit?(entry) do
    with %{} = agent <- Config.get_agent(entry["agent"]),
         false <- agent.exempt_message_limit do
      Pepe.Usage.over_message_limit?(Project.of(agent.name))
    else
      _ -> false
    end
  end

  @doc false
  # Second half, run by the lane in order: a command is carried out here (its state change
  # happens now, so the next message sees it) and its reply sent off in a task; a message for
  # the agent is *not* run here - the lane hands it to the session without waiting for the
  # turn (`{:chat, key, text, opts}`), so the next message in the conversation can still be
  # queued or folded into the turn the way an in-flight one always could.
  @spec begin(map(), String.t(), keyword()) :: {:chat, String.t(), String.t(), keyword()} | :done
  def begin(%{entry: entry, mod: mod, message: message}, text, opts) do
    from = message.from
    agent = entry["agent"]
    key = session_key(entry, from)

    case command(entry, text, actor(message)) do
      {:reset, reply} ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        Session.reset(key)
        reply_async(mod, entry, from, reply)

      {:reply, reply} ->
        reply_async(mod, entry, from, reply)

      {:model_show} ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        %{model: model} = Session.status(key)
        reply_async(mod, entry, from, "Current model: #{model || "(unset)"}")

      {:model_set, name, scope, perm} ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        reply_async(mod, entry, from, apply_model_change(key, agent, name, scope, perm))

      {:mention, waived?} ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        Session.set_mention_optional(key, waived?)
        reply_async(mod, entry, from, mention_reply(waived?))

      {:mention_status} ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        reply_async(mod, entry, from, mention_status_reply(Session.mention_optional?(key)))

      :chat ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))
        {:chat, key, text, chat_opts(entry, message, opts)}
    end
  end

  # A webhook sender is never the operator, the same "a stranger" content class every
  # Telegram attachment path already taints (Pepe.Permissions' taint model). Until now this
  # was the one inbound surface that never withdrew auto_approve for it.
  defp chat_opts(entry, message, opts) do
    [
      learn: learn?(entry, actor(message)),
      authorize: nil,
      untrusted: true,
      sender: Map.get(message, :name),
      # An inbound image, for a vision model: rides this turn only, never persisted.
      images: opts[:images]
    ]
  end

  @doc false
  # What the lane does with the session's answer to a message it handed over.
  @spec finish(map(), term()) :: :ok
  def finish(%{entry: entry, mod: mod, message: message}, result) do
    case result do
      {:ok, reply} ->
        deliver(mod, entry, message.from, reply)

      {:error, :busy} ->
        :ok

      {:error, reason} ->
        Logger.warning("[webhooks] #{entry["slug"]}: run failed: #{inspect(reason)}")
    end
  end

  defp reply_async(mod, entry, to, text) do
    Task.Supervisor.start_child(Pepe.Webhooks.TaskSupervisor, fn ->
      Config.put_locale()
      deliver(mod, entry, to, text)
    end)

    :done
  end

  defp deliver(mod, entry, to, text) do
    case mod.deliver(entry, to, text) do
      {:error, reason} -> Logger.warning("[webhooks] #{entry["slug"]}: could not deliver to #{to}: #{inspect(reason)}")
      _ -> :ok
    end
  end

  @doc """
  Decide how to treat a message: `{:reset, ack}` for `/new`, `{:reply, text}` for a
  read-only command answered right here (`/models`), `{:model_show}` /
  `{:model_set, name, scope, perm}` for `/model` (needs a live session, so
  `converse/4` executes it), or `:chat` (the default - also what a `support`
  connection or an unrecognized slash command gets). A pure decision function -
  the model-*change* actually happens in `converse/4`, not here.
  """
  def command(entry, "/" <> _ = text, from) do
    if entry["mode"] == "admin" and Map.get(entry, "commands", true) do
      [cmd | rest] = text |> String.trim_leading("/") |> String.split(~r/\s+/, parts: 2)
      dispatch_command(entry, cmd, List.first(rest) || "", from)
    else
      :chat
    end
  end

  def command(_entry, _text, _from), do: :chat

  defp dispatch_command(_entry, "new", _args, _from), do: {:reset, "🧹 New conversation."}

  defp dispatch_command(entry, "models", _args, _from) do
    {:reply, render_models(ModelSwitch.list_for(Project.of(entry["agent"])))}
  end

  defp dispatch_command(entry, "model", args, from) do
    perm = ModelSwitch.permission(learn?(entry, from), entry["model_switch_locked"] == true)

    case String.split(args, ~r/\s+/, trim: true) do
      [] -> {:model_show}
      [name] -> {:model_set, name, nil, perm}
      [name, scope] -> {:model_set, name, scope, perm}
      _ -> {:reply, "Usage: /model NAME [session|global]"}
    end
  end

  # A per-conversation waiver of the connection's require_mention gate (see
  # addressed?/3 and mention_waived?/2 above) - only matters for a provider that
  # actually implements addressed?/2 gating (Slack, MS Teams, Google Chat today);
  # a no-op where the connection already answers everything.
  defp dispatch_command(_entry, "mention", args, _from) do
    case args |> String.trim() |> String.downcase() do
      "off" -> {:mention, true}
      "on" -> {:mention, false}
      "" -> {:mention_status}
      _ -> {:reply, "Usage: /mention on|off"}
    end
  end

  defp dispatch_command(_entry, _other, _args, _from), do: :chat

  defp mention_reply(true), do: "👂 I'll reply here without being @mentioned, until /new."
  defp mention_reply(false), do: "📣 @mention required again in this chat."

  defp mention_status_reply(true),
    do: "Mention requirement is currently: off (I reply without being mentioned).\nUse /mention on or /mention off."

  defp mention_status_reply(false), do: "Mention requirement is currently: on (I need an @mention).\nUse /mention on or /mention off."

  defp render_models([]), do: "No models are configured for this project."

  defp render_models(models),
    do: "Available models:\n" <> Enum.map_join(models, "\n", &"- #{&1.name} (#{&1.model})")

  # `perm` was already computed in `command/3` (pure); this just applies it.
  defp apply_model_change(key, agent, name, scope, perm) do
    cond do
      is_nil(Config.get_model(name)) ->
        "Unknown model: #{name}"

      perm == :none ->
        "You don't have permission to change the model here."

      perm == :session or scope == "session" ->
        model_result(ModelSwitch.apply(key, agent, name, :session), name, :session)

      scope == "global" ->
        model_result(ModelSwitch.apply(key, agent, name, :global), name, :global)

      scope in [nil, ""] ->
        "Change #{name} for this conversation only, or for everyone? " <>
          "Reply /model #{name} session or /model #{name} global."

      true ->
        "Usage: /model NAME [session|global]"
    end
  end

  defp model_result(:ok, name, scope), do: "Model set to #{name} (#{scope})."
  defp model_result({:error, :unknown_model}, name, _scope), do: "Unknown model: #{name}"
  defp model_result({:error, :unknown_agent}, _name, _scope), do: "No agent to set the model on."

  # Per-connection session behaviour: an idle TTL (minutes -> ms; nil = never) and
  # whether history is ephemeral (support) or kept (admin).
  defp session_opts(entry) do
    ttl =
      case entry["session_ttl_min"] do
        n when is_integer(n) and n > 0 -> [ttl_ms: n * 60_000]
        _ -> []
      end

    ttl ++ [ephemeral: entry["ephemeral"] == true]
  end

  @doc "May `from` message this connection? `allowed_numbers` empty/absent = anyone."
  def allowed?(entry, from) do
    case entry["allowed_numbers"] do
      list when is_list(list) and list != [] -> from in list
      _ -> true
    end
  end

  @doc """
  Whether this conversation may become memory. `trainers`: `["*"]` = everyone,
  `[]` = no one (a support channel), `[ids]` = only those, absent/nil = default (all).
  """
  def learn?(entry, from) do
    case entry["trainers"] do
      ["*"] -> true
      [] -> false
      list when is_list(list) -> from in list
      _ -> true
    end
  end

  defp norm(c) when c in [nil, "", "root"], do: nil
  defp norm(c), do: c
end
