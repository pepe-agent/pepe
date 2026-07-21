defmodule Pepe.Gateways.TUI do
  @moduledoc """
  Interactive console gateway - a REPL backed by a persistent `Pepe.Agent.Session`.

  Like `mix pepe run`, but it *holds* the session: the conversation keeps context
  across turns and the same slash commands as the other gateways work - `/new`,
  `/undo`, `/compact`, `/status`, `/agent`, `/models`, `/model`, `/help`, `/exit`.
  Replies stream to stdout and risky tools prompt through the shared arrow-key
  permission menu (`Pepe.Permissions.Prompt`), scoped to the console session.

  It also exposes that console rendering - `stream_events/0` and `authorizer/0` -
  so the one-shot `run` command shares exactly the same output and prompt.

  There's no multi-user concept here - whoever runs `mix pepe chat` is the sole
  operator - so `/model` always offers the session-vs-global choice (no
  trainers/locked distinction like Telegram or the webhook channels).
  """

  use Gettext, backend: Pepe.Gettext

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Project
  alias Pepe.Config
  alias Pepe.ModelSwitch
  alias Pepe.Permissions.Prompt

  @default_session_key "tui:local"

  @doc """
  Start the console REPL bound to `agent_name`, on the given session `key`
  (defaults to `"tui:local"`). Blocks until the user exits.
  """
  @spec start(String.t(), String.t() | nil) :: :ok
  def start(agent_name, key \\ @default_session_key)
  def start(agent_name, nil), do: start(agent_name, @default_session_key)

  def start(agent_name, key) when is_binary(key) do
    Config.put_locale()
    {:ok, _pid} = SessionSupervisor.ensure(key, agent_name)
    subscribe_watches(key)
    print_header(agent_name, key)
    loop(key)
  end

  # Receive this console's fired watches, and register so the scheduler knows a live
  # surface is here. A watch created from the TUI (origin "tui:<key>") delivers back
  # to this same console.
  defp subscribe_watches(key) do
    topic = Pepe.Watch.Delivery.topic(%{"channel" => "tui", "key" => key})
    Phoenix.PubSub.subscribe(Pepe.PubSub, topic)
    Registry.register(Pepe.Watch.Subscribers, topic, nil)
  end

  # Print any watch notifications that arrived while we were blocked on input.
  defp drain_watches do
    receive do
      {:watch_message, _origin, text} ->
        IO.puts("\n" <> bold("🔭 watch › ") <> text)
        drain_watches()
    after
      0 -> :ok
    end
  end

  # A summary box (agent · model · session) shown when the console opens.
  defp print_header(agent_name, key) do
    agent = Config.get_agent(agent_name)
    model = agent && Config.model_for_agent(agent)

    rows = [
      {gettext("Agent"), agent_name},
      {gettext("Model"), model_label(model)},
      {gettext("Session"), key}
    ]

    box("🧠 Pepe", rows)
    info(dim(gettext("/help for commands · /exit to quit")))
  end

  defp model_label(nil), do: gettext("(no model set)")
  defp model_label(%{model: id, name: name}), do: "#{id} (#{name})"

  # Draw a rounded box: bold title, then dim-label / green-value rows, aligned.
  defp box(title, rows) do
    labelw = rows |> Enum.map(fn {k, _v} -> String.length(k) end) |> Enum.max()

    lines =
      [{title, bold(title)}] ++
        Enum.map(rows, fn {k, v} ->
          label = String.pad_trailing(k <> ":", labelw + 1)
          {label <> "  " <> v, dim(label) <> "  " <> green(v)}
        end)

    inner = lines |> Enum.map(fn {plain, _} -> vwidth(plain) end) |> Enum.max()
    rule = String.duplicate("─", inner + 2)

    info(dim("╭" <> rule <> "╮"))

    Enum.each(lines, fn {plain, colored} ->
      pad = String.duplicate(" ", max(0, inner - vwidth(plain)))
      info(dim("│ ") <> colored <> pad <> dim(" │"))
    end)

    info(dim("╰" <> rule <> "╯"))
  end

  # Display width: emoji/wide glyphs take two terminal cells, so the box aligns.
  defp vwidth(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, acc -> acc + if(cp >= 0x1F000, do: 2, else: 1) end)
  end

  @doc "An `:on_event` callback that streams agent activity (deltas + tools) to stdout."
  @spec stream_events() :: (term() -> :ok)
  def stream_events do
    fn
      {:assistant_delta, text} -> IO.write(text)
      {:tool_call, name, args} -> IO.write(dim("\n[-> #{name} #{one_line(args)}]\n"))
      {:tool_denied, name, nil} -> IO.write(dim("[✗ #{name} #{gettext("not allowed")}]\n"))
      {:tool_denied, name, reason} -> IO.write(dim("[✗ #{name} #{gettext("not allowed")}: #{reason}]\n"))
      {:tool_result, name, _out} -> IO.write(dim("[✓ #{name}]\n"))
      _ -> :ok
    end
  end

  @doc "The console `authorize` callback - an arrow-key menu over the shared options."
  @spec authorizer() :: (String.t(), term(), map() -> Pepe.Permissions.decision())
  def authorizer do
    fn name, args, ctx ->
      Config.put_locale()

      label =
        bold(Prompt.question(name)) <>
          risk_lines(name, args) <>
          "\n" <>
          dim(one_line(args)) <>
          "\n" <>
          dim(Prompt.scope_note(ctx[:risks] || []))

      case Pepe.TUI.select(Prompt.options(), label: label, render_as: &Prompt.label/1) do
        :deny -> maybe_deny_reason()
        decision -> decision
      end
    end
  end

  @doc "The console `ask_user` callback - an arrow-key menu over the tool's own choices."
  @spec ask_user_fn() :: (String.t(), [String.t()] -> {:ok, String.t()})
  def ask_user_fn do
    fn question, choices ->
      pick = Pepe.TUI.select(choices, label: bold(question))
      {:ok, pick}
    end
  end

  # Give a denial an optional free-text reason, threaded back into the agent's
  # context (see Pepe.Permissions.denied_message/2) instead of a bare refusal.
  defp maybe_deny_reason do
    case Owl.IO.input(label: "Reason (optional):", optional: true) do
      blank when blank in [nil, ""] -> :deny
      reason -> {:deny, reason}
    end
  end

  defp risk_lines(name, args) do
    map =
      case Jason.decode(to_string(args)) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    case Pepe.Permissions.Risk.hints(name, map) do
      [] -> ""
      kinds -> "\n" <> Enum.map_join(kinds, "\n", &("⚠️  " <> Pepe.Permissions.Risk.label(&1)))
    end
  end

  ###
  ### REPL
  ###

  defp loop(key) do
    drain_watches()

    case IO.gets("\n" <> bold("you › ")) do
      :eof ->
        :ok

      data ->
        text = String.trim(data)

        cond do
          text in ["/exit", "/quit"] ->
            :ok

          text == "" ->
            loop(key)

          String.starts_with?(text, "/") ->
            command(key, text)
            loop(key)

          true ->
            say(key, text)
            loop(key)
        end
    end
  end

  defp say(key, text) do
    IO.write(bold("\nbot › "))

    case Session.chat(key, text,
           stream: true,
           on_event: stream_events(),
           authorize: authorizer(),
           ask_user: ask_user_fn()
         ) do
      {:ok, _reply} -> IO.puts("")
      {:error, reason} -> error("\n#{inspect(reason)}")
    end
  end

  # Text of the most recent user message in a session, or nil (used by /retry).
  defp last_user_text(key) do
    key
    |> Session.history()
    |> Enum.reverse()
    |> Enum.find_value(fn m -> m["role"] == "user" && m["content"] end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp command(key, text) do
    {cmd, rest} =
      case String.split(text, ~r/\s+/, parts: 2) do
        ["/" <> c] -> {c, ""}
        ["/" <> c, r] -> {c, String.trim(r)}
      end

    run_command(key, cmd, rest)
  end

  defp run_command(key, cmd, _rest) when cmd in ["new", "reset"] do
    Session.reset(key)
    info(gettext("🧠 New conversation started."))
  end

  defp run_command(key, "undo", _rest) do
    Session.undo(key)
    info(gettext("↩️ Undid your last message."))
  end

  defp run_command(key, "retry", _rest) do
    case last_user_text(key) do
      nil ->
        info(gettext("Nothing to retry yet."))

      text ->
        Session.undo(key)
        say(key, text)
    end
  end

  defp run_command(key, "usage", _rest) do
    project = key |> Session.status() |> Map.get(:agent) |> Project.of()
    cost = Pepe.Usage.format_cost(Pepe.Usage.month_to_date(project))
    count = Pepe.Usage.message_count_month_to_date(project)
    info(gettext("This month: %{cost} · %{count} messages", cost: cost, count: count))
  end

  defp run_command(key, "learn", _rest) do
    Session.learn(key)
    info(gettext("🧠 Reviewing what I learned..."))
  end

  defp run_command(key, "compact", _rest) do
    case Session.compact(key) do
      {:ok, _summary} -> info(gettext("🗜️ History compacted."))
      {:error, _reason} -> error(gettext("I couldn't summarize right now. Try again shortly?"))
    end
  end

  defp run_command(key, "status", _rest) do
    s = Session.status(key)

    info(
      gettext("Agent: %{agent}\nModel: %{model}\nTurns: %{turns}",
        agent: s.agent || gettext("(default)"),
        model: s.model || gettext("(unset)"),
        turns: s.turns
      )
    )
  end

  defp run_command(_key, "agent", "") do
    info(gettext("Usage: /agent <name>"))
  end

  defp run_command(key, "agent", name) do
    if Config.get_agent(name) do
      Session.set_agent(key, name)
      info(gettext("Switched to agent %{name}.", name: name))
    else
      info(gettext("Unknown agent: %{name}", name: name))
    end
  end

  defp run_command(key, "models", _rest) do
    project = key |> Session.status() |> Map.get(:agent) |> Project.of()

    case ModelSwitch.list_for(project) do
      [] ->
        info(gettext("No models are configured for this project."))

      models ->
        info(
          gettext("Available models:") <>
            "\n" <> Enum.map_join(models, "\n", &"- #{&1.name} (#{&1.model})")
        )
    end
  end

  defp run_command(key, "model", "") do
    s = Session.status(key)
    info(gettext("Current model: %{model}", model: s.model || gettext("(unset)")))
  end

  defp run_command(key, "model", args) do
    case String.split(args, ~r/\s+/, trim: true) do
      [name] -> change_model(key, name, nil)
      [name, scope] -> change_model(key, name, scope)
      _ -> info(gettext("Usage: /model NAME [session|global]"))
    end
  end

  defp run_command(_key, "help", _rest) do
    info(
      gettext("Commands:") <>
        "\n/new  /undo  /retry  /compact  /learn  /usage  /status  /agent <name>  /models  /model <name> [session|global]  /help  /exit"
    )
  end

  defp run_command(_key, cmd, _rest) do
    info(gettext("Unknown command: /%{cmd}", cmd: cmd))
  end

  # No trainers/locked distinction here (single-operator console) - always the
  # `:global`-eligible ask-flow, same reasoning as the dashboard chat.
  defp change_model(key, name, scope) do
    cond do
      is_nil(Config.get_model(name)) ->
        info(gettext("Unknown model: %{name}", name: name))

      scope == "session" ->
        report_model_change(key, name, :session)

      scope == "global" ->
        report_model_change(key, name, :global)

      scope in [nil, ""] ->
        info(
          gettext(
            "Change to %{name} for this conversation only, or for everyone? Reply /model %{name} session or /model %{name} global.",
            name: name
          )
        )

      true ->
        info(gettext("Usage: /model NAME [session|global]"))
    end
  end

  defp report_model_change(key, name, scope) do
    agent_name = Session.status(key).agent

    case ModelSwitch.apply(key, agent_name, name, scope) do
      :ok ->
        info(gettext("Model set to %{name} (%{scope}).", name: name, scope: scope_label(scope)))

      {:error, :unknown_model} ->
        info(gettext("Unknown model: %{name}", name: name))

      {:error, :unknown_agent} ->
        info(gettext("There's no agent to set the model on."))
    end
  end

  defp scope_label(:session), do: gettext("this conversation only")
  defp scope_label(:global), do: gettext("everyone")

  ###
  ### output
  ###

  defp one_line(args) when is_binary(args),
    do: args |> String.replace("\n", " ") |> String.slice(0, 120)

  defp one_line(args), do: inspect(args)

  defp info(msg), do: IO.puts(msg)
  defp error(msg), do: IO.puts(:stderr, IO.ANSI.red() <> "✗ " <> IO.ANSI.reset() <> msg)
  defp green(s), do: IO.ANSI.green() <> s <> IO.ANSI.reset()
  defp bold(s), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()
end
