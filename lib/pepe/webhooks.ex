defmodule Pepe.Webhooks do
  @moduledoc """
  Inbound-webhook gateway - the WhatsApp-and-friends counterpart to the Telegram
  poller. A single route `/webhooks/:company/:provider/:slug` (see
  `PepeWeb.WebhookController`) dispatches here; each connection binds to an agent
  and runs it on a session keyed `provider:agent:from`.

  A connection is a config entry (`Pepe.Config` `"webhooks"`, keyed by its unique
  `slug`) with a `mode`:

    * `admin`   - like a Telegram owner bot: slash commands on, restricted to your
      own numbers (`allowed_numbers`), a trainer conversation.
    * `support` - customer-facing: slash commands off, open to anyone, never learns
      (`trainers: []`), and best paired with a locked-down agent (safe tools only,
      since there's no human to approve risky ones) and an ephemeral session TTL.
  """

  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config

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

  @doc "The `%{name => module}` map of every provider, built-in plugins last (they win)."
  def registry, do: Map.merge(@builtin_providers, plugin_providers())

  # A plugin provider is any plugin module exporting `name/0` plus the Provider callbacks.
  defp plugin_providers do
    [{:name, 0}, {:verify, 2}, {:authenticate, 3}, {:parse, 1}, {:deliver, 3}]
    |> Pepe.Plugins.implementing()
    |> Map.new(fn mod -> {mod.name(), mod} end)
  end

  @doc """
  Resolve a connection by its `(company, provider, slug)` path. The `slug` is the
  unique key; `company` and `provider` from the path are validated against the
  stored entry so a mismatched URL can't reach it. `\"root\"` in the path means the
  no-company scope. Returns the entry (with its slug) or `nil`.
  """
  def resolve(company, provider, slug) do
    with entry when is_map(entry) <- Config.get_webhook(slug),
         true <- entry["provider"] == provider,
         true <- norm(entry["company"]) == norm(company) do
      Map.put(entry, "slug", slug)
    else
      _ -> nil
    end
  end

  @doc "Answer a provider's verification handshake for this connection."
  def verify(company, provider, slug, params) do
    with entry when is_map(entry) <- resolve(company, provider, slug),
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
  def handle_inbound(company, provider, slug, raw_body, payload, headers) do
    with entry when is_map(entry) <- resolve(company, provider, slug),
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

  defp run_parse(mod, entry, payload) do
    if addressed?(mod, entry, payload) do
      case mod.parse(payload) do
        {:ok, messages} -> Enum.each(messages, &dispatch(entry, mod, &1))
        :ignore -> :ok
      end
    else
      :ok
    end
  end

  # A provider that implements `addressed?/2` gates on it (mention-in-group / DM
  # rules); one that hasn't added gating yet is always addressed (today's behavior).
  defp addressed?(mod, entry, payload) do
    if function_exported?(mod, :addressed?, 2), do: mod.addressed?(entry, payload), else: true
  end

  # Run one inbound message through the bound agent, off the request process.
  defp dispatch(entry, mod, %{from: from, text: text}) do
    if allowed?(entry, from) do
      Task.start(fn -> converse(entry, mod, from, text) end)
    else
      Logger.info("[webhooks] #{entry["slug"]}: ignored message from disallowed #{from}")
    end

    :ok
  end

  defp converse(entry, mod, from, text) do
    agent = entry["agent"]
    key = "#{entry["provider"]}:#{agent}:#{from}"

    case command(entry, text) do
      {:reset, reply} ->
        Session.reset(key)
        mod.deliver(entry, from, reply)

      :chat ->
        SessionSupervisor.ensure(key, agent, session_opts(entry))

        case Session.chat(key, text, learn: learn?(entry, from), authorize: nil) do
          {:ok, reply} ->
            mod.deliver(entry, from, reply)

          {:error, :busy} ->
            :ok

          {:error, reason} ->
            Logger.warning("[webhooks] #{entry["slug"]}: run failed: #{inspect(reason)}")
        end
    end
  end

  @doc """
  Decide how to treat a message: `{:reset, ack}` for a recognized slash command, or
  `:chat` (the default). Slash commands are honoured only for `admin` connections
  that enable them; a `support` channel treats `/new` as ordinary text.
  """
  def command(entry, "/" <> _ = text) do
    if entry["mode"] == "admin" and Map.get(entry, "commands", true) do
      case text |> String.trim_leading("/") |> String.split(~r/\s+/, parts: 2) |> hd() do
        "new" -> {:reset, "🧹 New conversation."}
        _ -> :chat
      end
    else
      :chat
    end
  end

  def command(_entry, _text), do: :chat

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
