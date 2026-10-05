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

  Set `agent_switch_locked` on the entry to refuse every way of changing which agent
  answers here - `/agent NAME` (even for a trainer), `switch_agent` (temporary handoff),
  and `manage_channel`'s `bind_topic`/`unbind_topic` (permanent handoff). `/agent` with no
  args (status), `/mention`, `/model` and `/new` are unaffected.
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

  @doc """
  The scheme+host every callback URL is built from. `PEPE_PUBLIC_URL` overrides outright;
  else falls back to `PHX_HOST` (already set for a release's endpoint, see
  `config/runtime.exs`) as `https://<host>`, else the `"YOUR_HOST"` placeholder. Reads the
  raw env var, not `Application.get_env` - `config/runtime.exs` never runs under plain
  `mix pepe ...`.
  """
  def public_host do
    System.get_env("PEPE_PUBLIC_URL") ||
      case System.get_env("PHX_HOST") do
        host when is_binary(host) and host != "" -> "https://" <> host
        _ -> "https://YOUR_HOST"
      end
  end

  @doc "The full callback URL for a connection - what gets pasted into the provider's own webhook config."
  def callback_url(project, provider, slug), do: "#{public_host()}/webhooks/#{project || "root"}/#{provider}/#{slug}"

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
    cond do
      not bot_accepted?(entry, message) ->
        :ok

      real_command?(entry, message) or addressed?(mod, entry, payload) or mention_waived?(entry, from) ->
        dispatch(entry, mod, message)

      true ->
        :ok
    end
  end

  # A message written by a bot or an integration (a provider marks it with `:bot`, a map with
  # the ids it knows: `:id`, `:app`, and a `:name`) is dropped unless the connection lists that
  # bot in `accept_bots`: ids only, never a name, which anyone with access to the channel can
  # set. A channel that gets its tasks from another system (a help desk posting each new ticket)
  # lists that system's app id. What is dropped is logged with the ids, so the one to list can
  # be read off the log instead of guessed. A provider that never sets `:bot` is unaffected.
  defp bot_accepted?(entry, %{bot: bot} = message) when is_map(bot) do
    ids = [bot[:id], bot[:app]] |> Enum.filter(&is_binary/1)

    if Enum.any?(ids, &(&1 in accepted_bots(entry))) do
      true
    else
      Logger.info(
        "[webhooks] ignored a message from a bot in #{message.from} (bot=#{inspect(bot[:id])} app=#{inspect(bot[:app])} " <>
          "name=#{inspect(bot[:name])}); to answer it, add its id to this connection's accept_bots"
      )

      false
    end
  end

  defp bot_accepted?(_entry, _message), do: true

  defp accepted_bots(entry) do
    case (entry["config"] || %{})["accept_bots"] do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      text when is_binary(text) -> text |> String.split([",", " "], trim: true)
      _ -> []
    end
  end

  # A real, recognized command (/new, /model, /mention, ...) is unambiguously addressed to the
  # bot by its own syntax alone - unlike a plain "oi", which could be meant for anyone in a busy
  # channel, nobody types "/mention off" by accident. Requiring an @mention on top of that was
  # pure friction with no actual ambiguity to resolve, so a genuine command reaches the agent
  # regardless of addressed?/2 and the channel's mention setting; a support connection, or text that merely starts
  # with "/" but isn't a command command/3 recognizes, still falls through to the ordinary gate
  # below, exactly as before - command/3 already returns :chat for both of those cases on its own.
  defp real_command?(entry, message) do
    case command(entry, message[:text] || "", actor(message)) do
      :chat -> false
      _ -> true
    end
  end

  # A provider that implements `addressed?/2` gates on it (mention-in-group / DM
  # rules); one that hasn't added gating yet is always addressed (today's behavior).
  defp addressed?(mod, entry, payload) do
    if function_exported?(mod, :addressed?, 2), do: mod.addressed?(entry, payload), else: true
  end

  # Does this conversation answer without being @mentioned? Strongest first: what was said in
  # the conversation itself (`/mention on|off`, forgotten at `/new`), then what was set for the
  # channel for good (`/mention off always`), then the default, which is to require a mention.
  # Kept per conversation and channel, never on the connection, so it never leaks into another
  # channel, and the channel's own setting survives `/new` and a restart.
  defp mention_waived?(entry, from) do
    case session_mention_setting(entry, from) do
      nil -> Config.channel_mention_optional?(mention_key(entry, from))
      setting -> setting
    end
  end

  defp session_mention_setting(entry, from) do
    key = session_key(entry, from)
    SessionSupervisor.ensure(key, entry["agent"], session_opts(entry))
    Session.mention_setting(key)
  end

  # The durable setting belongs to the channel on this connection, not to the agent answering
  # in it: the session key carries the agent, so a channel moved to another agent with `/agent`
  # would lose it. Qualified by the connection's slug, so two workspaces never share one.
  @doc false
  def mention_key(entry, from), do: "#{entry["slug"]}:#{from}"

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
    # This runs in the lane's own process, a different one from whichever task last called
    # Config.put_locale/0 (Gettext's locale is per-process) - every command reply built below
    # (command/3, dispatch_command/4, and their own helpers) needs it set here, not just in
    # reply_async/4's task, since the text is already a finished string by the time it gets
    # there.
    Config.put_locale()
    from = message.from
    agent = entry["agent"]
    key = session_key(entry, from)
    # A context bag rather than several positional args threaded through every clause below -
    # handle_command/2's own clauses are what keep this dispatch's cyclomatic complexity down
    # (one function per command shape, instead of one long case), not this struct-less map.
    ctx = %{entry: entry, mod: mod, message: message, text: text, opts: opts, agent: agent, key: key, from: from}

    # A typed "allow" / "deny" answering a permission question the agent is waiting on is that
    # answer, not a message for the agent (Pepe.Webhooks.Approval).
    case Pepe.Webhooks.Approval.reply(entry, key, actor(message), text) do
      :consumed -> :done
      :pass -> run_message(ctx)
    end
  end

  defp run_message(%{entry: entry, message: message, text: text, agent: agent, key: key} = ctx) do
    result = handle_command(command(entry, text, actor(message)), ctx)
    # Reasserted AFTER dispatch, not before: /new's own reset (see Session.reset/1) reverts
    # to the connection's plain default, and running this first would have that stomp right
    # back over it within the very same turn. Landing here means whichever command just ran,
    # this always has the final word - same "authoritative every turn" as
    # Pepe.Gateways.Telegram's bind_and_resolve_agent/1, and it also covers a plain :chat turn,
    # since nothing else reasserts before the message reaches the session.
    apply_channel_binding(key, agent, entry)
    result
  end

  defp handle_command({:reset, reply}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    Session.reset(ctx.key)
    reply_async(ctx.mod, ctx.entry, ctx.from, reply)
  end

  defp handle_command({:reply, reply}, ctx), do: reply_async(ctx.mod, ctx.entry, ctx.from, reply)

  defp handle_command({:model_show}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    %{model: model} = Session.status(ctx.key)
    model_label = model || dgettext("webhooks", "(unset)")
    reply_async(ctx.mod, ctx.entry, ctx.from, dgettext("webhooks", "Current model: %{model}", model: model_label))
  end

  defp handle_command({:model_set, name, scope, perm}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    reply_async(ctx.mod, ctx.entry, ctx.from, apply_model_change(ctx.key, ctx.agent, name, scope, perm))
  end

  # `/mention off|on` is this conversation only, forgotten at `/new`; with `always` it is set
  # for the channel and kept. Setting it for the channel clears what the conversation said, so
  # the channel's own setting is what shows; `on always` is just the default again (a mention
  # is required), so it clears the stored one.
  defp handle_command({:mention, waived?, always?}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    channel_key = mention_key(ctx.entry, ctx.from)
    kept? = Config.channel_mention_optional?(channel_key)

    if always? do
      Session.set_mention_optional(ctx.key, nil)
      Config.put_channel_mention_optional(channel_key, waived?)
    else
      Session.set_mention_optional(ctx.key, waived?)
    end

    reply_async(ctx.mod, ctx.entry, ctx.from, mention_reply(waived?, always?, kept?))
  end

  defp handle_command({:mention_status}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    kept? = Config.channel_mention_optional?(mention_key(ctx.entry, ctx.from))
    reply_async(ctx.mod, ctx.entry, ctx.from, mention_status_reply(Session.mention_setting(ctx.key), kept?))
  end

  defp handle_command({:agent_status}, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))

    reply_async(
      ctx.mod,
      ctx.entry,
      ctx.from,
      agent_status_reply(Config.channel_agent(ctx.key), ctx.agent, ctx.entry["agent_switch_locked"] == true)
    )
  end

  defp handle_command({:agent_bind, _target, false}, ctx),
    do: reply_async(ctx.mod, ctx.entry, ctx.from, dgettext("webhooks", "You don't have permission to change this channel's agent."))

  defp handle_command({:agent_bind, nil, true}, ctx) do
    Config.bind_channel_agent(ctx.key, nil)
    default_agent = ctx.agent || Config.default_agent_name()
    SessionSupervisor.ensure(ctx.key, default_agent, session_opts(ctx.entry))
    Session.set_agent(ctx.key, default_agent)
    reply = dgettext("webhooks", "This channel is no longer bound to a specific agent - back to %{agent}.", agent: default_agent)
    reply_async(ctx.mod, ctx.entry, ctx.from, reply)
  end

  defp handle_command({:agent_bind, target, true}, ctx) do
    reply_async(ctx.mod, ctx.entry, ctx.from, bind_channel_agent(ctx.key, ctx.agent, ctx.entry, target))
  end

  defp handle_command(:chat, ctx) do
    SessionSupervisor.ensure(ctx.key, ctx.agent, session_opts(ctx.entry))
    {:chat, ctx.key, ctx.text, chat_opts(ctx)}
  end

  # The connection's own default agent is `entry["agent"]`; a persistent bind_topic (or
  # `/agent NAME`) can override it for THIS conversation specifically - reasserted here, every
  # turn, so it always wins regardless of whatever a switch_agent handoff or /new left the
  # session on (the same "authoritative every turn" pattern Pepe.Gateways.Telegram's
  # bind_and_resolve_agent/1 already uses).
  defp apply_channel_binding(key, agent, entry) do
    case Config.channel_agent(key) do
      bound when is_binary(bound) ->
        if Config.get_agent(bound) do
          SessionSupervisor.ensure(key, agent, session_opts(entry))
          Session.set_agent(key, bound)
        end

      _ ->
        :ok
    end
  end

  # A bare name resolves inside the connection's own project, the same as /model and
  # switch_agent already do; an explicitly cross-project handle ("other/agent") is refused
  # exactly like an unknown one - never confirmed as "real, just not yours" - so a trainer on
  # one tenant's connection can't durably bind a channel to another tenant's agent, or even
  # learn whether a given name exists there.
  defp bind_channel_agent(key, agent, entry, target) do
    qualified = Project.qualify(target, agent || "")

    if Project.same_scope?(qualified, agent || "") and Config.get_agent(qualified) do
      Config.bind_channel_agent(key, qualified)
      SessionSupervisor.ensure(key, agent, session_opts(entry))
      Session.set_agent(key, qualified)
      dgettext("webhooks", "This channel is now bound to agent %{name} (kept across /new and restarts).", name: qualified)
    else
      unknown_agent(target)
    end
  end

  defp agent_status_reply(nil, agent, false),
    do:
      dgettext(
        "webhooks",
        "This channel isn't bound to a specific agent - it uses %{agent} (this connection's default).\nUse /agent NAME to bind it.",
        agent: agent
      )

  defp agent_status_reply(bound, _agent, false),
    do: dgettext("webhooks", "This channel is bound to agent %{name}.\nUse /agent NAME to change it, or /agent none to clear.", name: bound)

  defp agent_status_reply(nil, agent, true),
    do:
      dgettext(
        "webhooks",
        "This channel isn't bound to a specific agent - it uses %{agent} (this connection's default). Agent switching is locked here.",
        agent: agent
      )

  defp agent_status_reply(bound, _agent, true),
    do: dgettext("webhooks", "This channel is bound to agent %{name}. Agent switching is locked here.", name: bound)

  defp unknown_agent(name), do: dgettext("webhooks", "Unknown agent: %{name}", name: name)

  defp mention_denied_message,
    do:
      dgettext(
        "webhooks",
        "You don't have permission to change whether this channel needs an @mention. Ask one of this channel's trainers."
      )

  defp agent_switch_locked_message,
    do: dgettext("webhooks", "Agent switching is locked on this channel.")

  # A webhook sender is never the operator, the same "a stranger" content class every
  # Telegram attachment path already taints (Pepe.Permissions' taint model). Until now this
  # was the one inbound surface that never withdrew auto_approve for it.
  defp chat_opts(%{entry: entry, message: message, opts: opts} = ctx) do
    [
      learn: learn?(entry, actor(message)),
      # Asks in the conversation itself, in plain text, when the connection names its approvers
      # (Pepe.Webhooks.Approval); otherwise there is nobody to ask and only what is
      # pre-approved runs.
      authorize: Pepe.Webhooks.Approval.authorizer(entry, ctx.mod, ctx.from, ctx.key),
      untrusted: true,
      sender: Map.get(message, :name),
      # An inbound image, for a vision model: rides this turn only, never persisted.
      images: opts[:images],
      # Refuses switch_agent and manage_channel's bind_topic/unbind_topic for this turn -
      # see the comment on Pepe.Agent.Runtime.run_chain/3's own ctx field.
      agent_switch_locked: entry["agent_switch_locked"] == true
    ]
  end

  @doc false
  # Tell the platform the agent is on this message (or done with it), for providers that can
  # show it. Fire and forget: the signal is a courtesy, never something a reply waits on.
  @spec working(map(), :start | :stop) :: :ok
  def working(%{entry: entry, mod: mod, message: message}, state) do
    if function_exported?(mod, :working, 3) do
      Task.Supervisor.start_child(Pepe.Webhooks.TaskSupervisor, fn -> signal_working(mod, entry, message, state) end)
    end

    :ok
  end

  defp signal_working(mod, entry, message, state) do
    with {:error, reason} <- mod.working(entry, message, state) do
      Logger.debug("[webhooks] #{entry["slug"]}: working(#{state}) failed: #{inspect(reason)}")
    end

    :ok
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

  defp dispatch_command(_entry, "new", _args, _from), do: {:reset, dgettext("webhooks", "🧹 New conversation.")}

  defp dispatch_command(entry, "models", _args, _from) do
    {:reply, render_models(ModelSwitch.list_for(Project.of(entry["agent"])))}
  end

  defp dispatch_command(entry, "model", args, from) do
    perm = ModelSwitch.permission(learn?(entry, from), entry["model_switch_locked"] == true)

    case String.split(args, ~r/\s+/, trim: true) do
      [] -> {:model_show}
      [name] -> {:model_set, name, nil, perm}
      [name, scope] -> {:model_set, name, scope, perm}
      _ -> {:reply, model_usage()}
    end
  end

  # `/mention [on|off] [always]`: whether this channel answers without being @mentioned (see
  # mention_waived?/2 above) - only matters for a provider that implements addressed?/2 gating
  # (Slack, Discord, MS Teams, Google Chat); a no-op where every message is addressed anyway.
  #
  # Changing it is trainer-gated (learn?/2), like `/agent` and `/model ... global`: it changes
  # how the whole channel behaves for everyone in it. Reading the status stays open to all.
  defp dispatch_command(entry, "mention", args, from) do
    trainer? = learn?(entry, from)

    case args |> String.trim() |> String.downcase() |> String.split(~r/\s+/, trim: true) do
      [] -> {:mention_status}
      [change | _] when change in ["on", "off"] and not trainer? -> {:reply, mention_denied_message()}
      ["off"] -> {:mention, true, false}
      ["on"] -> {:mention, false, false}
      ["off", "always"] -> {:mention, true, true}
      ["on", "always"] -> {:mention, false, true}
      _ -> {:reply, dgettext("webhooks", "Usage: /mention on|off [always]")}
    end
  end

  # `/agent NAME` durably binds THIS conversation to an agent - kept across /new and
  # restarts, reasserted every turn (see apply_channel_binding/3), same as Telegram's own
  # `/agent`. Trainer-gated (learn?/2), the same allowlist that already controls memory and
  # `/model ... global` - a channel's routing is a shared, lasting decision, not something any
  # allowed sender should get to make unilaterally.
  defp dispatch_command(entry, "agent", args, from) do
    trainer? = learn?(entry, from)
    locked? = entry["agent_switch_locked"] == true

    case String.trim(args) do
      "" ->
        {:agent_status}

      _ when locked? ->
        {:reply, agent_switch_locked_message()}

      target when target in ["none", "clear", "off"] ->
        {:agent_bind, nil, trainer?}

      target ->
        {:agent_bind, target, trainer?}
    end
  end

  defp dispatch_command(_entry, _other, _args, _from), do: :chat

  defp mention_reply(true, false, _kept?),
    do: dgettext("webhooks", "👂 I'll reply here without being @mentioned, until /new.")

  defp mention_reply(true, true, _kept?),
    do:
      dgettext(
        "webhooks",
        "👂 I'll reply here without being @mentioned, even after /new, until you send /mention on always."
      )

  # A mention required again for this conversation only, while the channel itself is set to
  # answer without one: say that it comes back, instead of implying it is settled.
  defp mention_reply(false, false, true) do
    dgettext(
      "webhooks",
      "📣 @mention required again until /new. This channel is still set to answer without one, so that comes back after /new."
    )
  end

  defp mention_reply(false, false, false), do: dgettext("webhooks", "📣 @mention required again in this chat.")

  defp mention_reply(false, true, _kept?),
    do: dgettext("webhooks", "📣 @mention required again in this channel, for good.")

  defp mention_status_reply(true, _kept?),
    do:
      dgettext(
        "webhooks",
        "Mention requirement is currently: off until /new (I reply without being mentioned).\nUse /mention on or /mention off; add always to keep it for this channel."
      )

  defp mention_status_reply(false, true),
    do:
      dgettext(
        "webhooks",
        "Mention requirement is currently: on until /new. This channel is set to answer without one, so that comes back after /new.\nUse /mention on always to change the channel."
      )

  defp mention_status_reply(nil, true),
    do:
      dgettext(
        "webhooks",
        "Mention requirement is currently: off for this channel, kept after /new (I reply without being mentioned).\nUse /mention on always to undo it."
      )

  defp mention_status_reply(_setting, false),
    do:
      dgettext(
        "webhooks",
        "Mention requirement is currently: on (I need an @mention).\nUse /mention off, or /mention off always to keep it for this channel."
      )

  defp render_models([]), do: dgettext("webhooks", "No models are configured for this project.")

  defp render_models(models),
    do: dgettext("webhooks", "Available models:") <> "\n" <> Enum.map_join(models, "\n", &"- #{&1.name} (#{&1.model})")

  defp model_usage, do: dgettext("webhooks", "Usage: /model NAME [session|global]")
  defp unknown_model(name), do: dgettext("webhooks", "Unknown model: %{name}", name: name)

  # `perm` was already computed in `command/3` (pure); this just applies it.
  defp apply_model_change(key, agent, name, scope, perm) do
    cond do
      is_nil(Config.get_model(name)) ->
        unknown_model(name)

      perm == :none ->
        dgettext("webhooks", "You don't have permission to change the model here.")

      perm == :session or scope == "session" ->
        model_result(ModelSwitch.apply(key, agent, name, :session), name, :session)

      scope == "global" ->
        model_result(ModelSwitch.apply(key, agent, name, :global), name, :global)

      scope in [nil, ""] ->
        dgettext(
          "webhooks",
          "Change %{name} for this conversation only, or for everyone? Reply /model %{name} session or /model %{name} global.",
          name: name
        )

      true ->
        model_usage()
    end
  end

  defp model_result(:ok, name, scope), do: dgettext("webhooks", "Model set to %{name} (%{scope}).", name: name, scope: scope)
  defp model_result({:error, :unknown_model}, name, _scope), do: unknown_model(name)
  defp model_result({:error, :unknown_agent}, _name, _scope), do: dgettext("webhooks", "No agent to set the model on.")

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
