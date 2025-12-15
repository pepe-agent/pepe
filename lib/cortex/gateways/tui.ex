defmodule Cortex.Gateways.TUI do
  @moduledoc """
  Interactive console gateway — a REPL backed by a persistent `Cortex.Agent.Session`.

  Like `mix cortex run`, but it *holds* the session: the conversation keeps context
  across turns and the same slash commands as the other gateways work — `/new`,
  `/undo`, `/compact`, `/status`, `/agent`, `/help`, `/exit`. Replies stream to
  stdout and risky tools prompt through the shared arrow-key permission menu
  (`Cortex.Permissions.Prompt`), scoped to the console session.

  It also exposes that console rendering — `stream_events/0` and `authorizer/0` —
  so the one-shot `run` command shares exactly the same output and prompt.
  """

  use Gettext, backend: Cortex.Gettext

  alias Cortex.Agent.Session
  alias Cortex.Agent.SessionSupervisor
  alias Cortex.Config
  alias Cortex.Permissions.Prompt

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
    print_header(agent_name, key)
    loop(key)
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

    box("🧠 Cortex", rows)
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
      {:tool_call, name, args} -> IO.write(dim("\n[→ #{name} #{one_line(args)}]\n"))
      {:tool_denied, name} -> IO.write(dim("[✗ #{name} #{gettext("not allowed")}]\n"))
      {:tool_result, name, _out} -> IO.write(dim("[✓ #{name}]\n"))
      _ -> :ok
    end
  end

  @doc "The console `authorize` callback — an arrow-key menu over the shared options."
  @spec authorizer() :: (String.t(), term(), map() -> Cortex.Permissions.decision())
  def authorizer do
    fn name, args, _ctx ->
      Config.put_locale()
      label = bold(Prompt.question(name)) <> "\n" <> dim(one_line(args))
      Cortex.TUI.select(Prompt.options(), label: label, render_as: &Prompt.label/1)
    end
  end

  ###
  ### REPL
  ###

  defp loop(key) do
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
           authorize: authorizer()
         ) do
      {:ok, _reply} -> IO.puts("")
      {:error, reason} -> error("\n#{inspect(reason)}")
    end
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

  defp run_command(_key, "help", _rest) do
    info(gettext("Commands:") <> "\n/new  /undo  /compact  /status  /agent <name>  /help  /exit")
  end

  defp run_command(_key, cmd, _rest) do
    info(gettext("Unknown command: /%{cmd}", cmd: cmd))
  end

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
