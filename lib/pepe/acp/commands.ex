defmodule Pepe.ACP.Commands do
  @moduledoc """
  The slash commands an editor's chat panel can offer, and what they do.

  Every other surface already has a command layer (`/new`, `/undo`, `/rewind`, `/model`
  ...), each a thin shell over `Pepe.Agent.Session` and `Pepe.ModelSwitch`. This is the
  editor's: the same calls, the same words (the translated messages are the console's),
  answered as an agent message instead of printed or sent. No command logic lives here
  that a session doesn't already own.

  Two properties worth knowing:

    * **Commands don't reach the model.** `/rewind 2` is a change to the conversation,
      not a request to it, so it is answered on the spot. A `/something` this list does
      not contain is *not* an error: it goes to the model as an ordinary message, exactly
      as it does on Telegram, because "/etc/hosts is unreadable" is a sentence a person
      may type. Only a prompt that is a single text block is ever read as a command, so
      one carrying attachments is never hijacked.
    * **Some run while a turn is in flight, some don't.** Reading state (`/status`,
      `/models`, `/tools`, `/usage`, `/help`, `/context`) and steering the turn
      (`/steer`, `/queue`) work at any time. Anything that rewrites the conversation
      waits for the turn to finish, the same refusal `/undo` and `/rewind` give.

  `run/3` returns what the server should do next: answer with text (`{:reply, text}`),
  start a normal turn with some text (`{:prompt, text}` - what `/steer` and `/queue`
  become when nothing is running), or hold text until the running turn ends
  (`{:queue, text}`).
  """

  use Gettext, backend: Pepe.Gettext

  alias Pepe.Agent.Compaction
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.ModelSwitch
  alias Pepe.Project
  alias Pepe.Skills.Commands, as: SkillCommands

  # name, the description an editor shows in its command palette, and the hint for its
  # argument. These are protocol metadata read by an editor, so they stay in English,
  # like the tool titles; what a command *says back* is translated.
  @commands [
    {"help", "List the available commands", nil},
    {"new", "Start a new conversation", nil},
    {"reset", "Start a new conversation (same as /new)", nil},
    {"undo", "Take back your last message", nil},
    {"rewind", "List recent turns, or go back N turns of the conversation and the files they changed", "N [chat|files]"},
    {"retry", "Ask your last message again", "files (also put back the files it changed)"},
    {"compact", "Summarize older history to free up context", nil},
    {"status", "Show the agent, the model and the turn count", nil},
    {"context", "Show how full the model's context window is", nil},
    {"model", "Show or change the model for this conversation", "model name [session|global]"},
    {"models", "List the models you can switch to", nil},
    {"tools", "List the tools this agent has", nil},
    {"usage", "Show this month's spend and message count", nil},
    {"steer", "Give guidance to the turn that is running now", "guidance for the running turn"},
    {"queue", "Run a prompt after the current turn finishes", "prompt to run next"},
    {"skill", "Run an installed skill", "skill name and its input"},
    {"version", "Show the Pepe version", nil}
  ]

  @names Enum.map(@commands, &elem(&1, 0))

  # An installed skill is offered as a command of its own, unless a built-in already has its
  # name. Which ones is per session: the agent's tools and the project's directory decide.
  @type skill_opts :: [agent: String.t() | nil, cwd: String.t() | nil]

  @type ctx :: %{
          required(:key) => String.t(),
          required(:agent) => String.t() | nil,
          required(:running?) => boolean(),
          optional(:last_usage) => %{used: integer(), size: integer()} | nil,
          optional(:cwd) => String.t() | nil
        }
  @type result :: {:reply, String.t()} | {:prompt, String.t()} | {:prompt, String.t(), String.t()} | {:queue, String.t()}

  @doc """
  The `availableCommands` an editor is told about: the built-ins, then one per installed
  skill the session's agent is offered (see `Pepe.Skills.Commands`).
  """
  @spec available(skill_opts()) :: [map()]
  def available(opts \\ []) do
    builtin =
      Enum.map(@commands, fn {name, description, hint} ->
        base = %{"name" => name, "description" => description}
        if hint, do: Map.put(base, "input", %{"hint" => hint}), else: base
      end)

    skills =
      for %{name: name, summary: summary} <- SkillCommands.list(skill_opts(opts) ++ [reserved: @names]) do
        %{"name" => name, "description" => summary, "input" => %{"hint" => "what the skill should work on"}}
      end

    builtin ++ skills
  end

  @doc "Is a `session/prompt`'s content a command? Only a lone text block ever is."
  @spec from_blocks(term(), skill_opts()) :: {:command, String.t(), String.t()} | :none
  def from_blocks(blocks, opts \\ [])
  def from_blocks([%{"type" => "text", "text" => text}], opts) when is_binary(text), do: parse(text, opts)
  def from_blocks(_other, _opts), do: :none

  @doc """
  Parse `/name args`; `:none` for anything that isn't one of our commands. An installed skill
  the session is offered counts as one: `/deploy staging` is `/skill deploy staging`.
  """
  @spec parse(String.t(), skill_opts()) :: {:command, String.t(), String.t()} | :none
  def parse(text, opts \\ []) do
    case Regex.run(~r{\A\s*/([A-Za-z][A-Za-z0-9_-]*)(?:\s+(.*))?\z}s, text) do
      [_, name] -> known(name, "", opts)
      [_, name, args] -> known(name, String.trim(args), opts)
      _ -> :none
    end
  end

  defp known(name, args, opts) do
    lowered = String.downcase(name)

    cond do
      lowered in @names -> {:command, lowered, args}
      match?({:ok, _}, SkillCommands.find(name, skill_opts(opts))) -> {:command, "skill", String.trim(name <> " " <> args)}
      true -> :none
    end
  end

  defp skill_opts(opts), do: [agent: opts[:agent], channel: "acp", cwd: opts[:cwd]]

  ###
  ### commands
  ###

  @doc "What `/queue` answers when a prompt is put behind the running turn."
  @spec queued(pos_integer()) :: String.t()
  def queued(count), do: gettext("Queued for after the current turn. (%{count} waiting)", count: count)

  @doc "Run one command against a session."
  @spec run(String.t(), String.t(), ctx()) :: result()
  def run("help", _args, _ctx), do: {:reply, help()}

  def run(name, _args, ctx) when name in ["new", "reset"] do
    idle(ctx, fn ->
      with :ok <- ensure(ctx) do
        Session.reset(ctx.key)
        {:reply, gettext("🧠 New conversation started.")}
      end
    end)
  end

  def run("undo", _args, ctx) do
    idle_ready(ctx, fn ->
      # A conversation-only take-back; if that turn had changed files, say they were left alone.
      case Session.rewind_to(ctx.key, 1, :chat, roots: roots(ctx)) do
        {:ok, result} ->
          {:reply, Enum.join([gettext("↩️ Undid your last message.") | Pepe.Checkpoints.Report.kept_lines(result.kept)], "\n")}

        {:error, :busy} ->
          wait()
      end
    end)
  end

  def run("rewind", args, ctx) do
    idle_ready(ctx, fn ->
      case Pepe.Checkpoints.Report.parse_rewind(args) do
        :list ->
          {:reply, Pepe.Checkpoints.Report.turn_list(Session.turns(ctx.key))}

        {:ok, count, mode} ->
          rewind(ctx, count, mode)

        :error ->
          {:reply, gettext("Usage: /rewind N, where N is how many turns to go back.") <> "\n" <> Pepe.Checkpoints.Report.usage()}
      end
    end)
  end

  # Ask the last message again: the turn is taken back and its text becomes a normal turn.
  # `files` also puts back what that turn changed, and says so before the new turn starts.
  def run("retry", args, ctx) do
    idle_ready(ctx, fn ->
      mode = if args |> String.trim() |> String.downcase() == "files", do: :both, else: :chat

      case Session.retry(ctx.key, mode, roots: roots(ctx)) do
        {:ok, %{text: text, files: files, roots: roots}} ->
          retry_prompt(text, Pepe.Checkpoints.Report.file_lines(files, roots: roots))

        {:error, :nothing} ->
          {:reply, gettext("Nothing to retry yet.")}

        {:error, :not_text} ->
          {:reply, gettext("That message had an attachment, so it can't be sent again exactly. Send it again yourself.")}

        {:error, :busy} ->
          wait()
      end
    end)
  end

  def run("compact", _args, ctx) do
    idle_ready(ctx, fn ->
      case Session.compact(ctx.key) do
        {:ok, _summary} -> {:reply, gettext("🗜️ History compacted.")}
        {:error, _reason} -> {:reply, gettext("I couldn't summarize right now. Try again shortly?")}
      end
    end)
  end

  def run("status", _args, ctx) do
    with :ok <- ensure(ctx) do
      s = Session.status(ctx.key)

      {:reply,
       gettext("Agent: %{agent}\nModel: %{model}\nTurns: %{turns}",
         agent: s.agent || gettext("(default)"),
         model: s.model || gettext("(unset)"),
         turns: s.turns
       )}
    end
  end

  def run("context", _args, ctx) do
    with :ok <- ensure(ctx) do
      s = Session.status(ctx.key) |> Map.put(:model_name, Session.model_name(ctx.key))
      model_line = gettext("Current model: %{model}", model: s.model || gettext("(unset)"))

      {:reply, Enum.join([model_line | context_lines(s, ctx[:last_usage])], "\n")}
    end
  end

  def run("models", _args, ctx) do
    with :ok <- ensure(ctx) do
      project = ctx.key |> Session.status() |> Map.get(:agent) |> Project.of()

      case ModelSwitch.list_for(project) do
        [] ->
          {:reply, gettext("No models are configured for this project.")}

        models ->
          {:reply, gettext("Available models:") <> "\n" <> Enum.map_join(models, "\n", &"- #{&1.name} (#{&1.model})")}
      end
    end
  end

  def run("model", args, ctx) do
    with :ok <- ensure(ctx) do
      case String.split(args, ~r/\s+/, trim: true) do
        [] ->
          s = Session.status(ctx.key)
          {:reply, gettext("Current model: %{model}", model: s.model || gettext("(unset)"))}

        [name] ->
          change_model(ctx, name, :session)

        [name, scope] when scope in ["session", "global"] ->
          change_model(ctx, name, String.to_existing_atom(scope))

        _ ->
          {:reply, gettext("Usage: /model NAME [session|global]")}
      end
    end
  end

  def run("tools", _args, ctx) do
    with :ok <- ensure(ctx) do
      {:reply, tools_text(ctx.key)}
    end
  end

  def run("usage", _args, ctx) do
    with :ok <- ensure(ctx) do
      project = ctx.key |> Session.status() |> Map.get(:agent) |> Project.of()
      cost = Pepe.Usage.format_cost(Pepe.Usage.month_to_date(project))
      count = Pepe.Usage.message_count_month_to_date(project)
      {:reply, gettext("This month: %{cost} · %{count} messages", cost: cost, count: count)}
    end
  end

  def run("steer", "", _ctx), do: {:reply, gettext("Usage: /steer <guidance>")}

  # Folded into the turn already running, picked up before its next model call. With
  # nothing running there is nothing to steer, so the guidance simply becomes the next
  # message - which is what the person meant by sending it.
  def run("steer", text, %{running?: true} = ctx) do
    case Session.inline(ctx.key, text) do
      :ok -> {:reply, gettext("⏩ Steer sent to the running turn.")}
      {:error, :not_running} -> {:prompt, text}
    end
  end

  def run("steer", text, _ctx), do: {:prompt, text}

  def run("queue", "", _ctx), do: {:reply, gettext("Usage: /queue <prompt>")}
  def run("queue", text, %{running?: true}), do: {:queue, text}
  def run("queue", text, _ctx), do: {:prompt, text}

  def run("skill", "", ctx), do: {:reply, skills_text(ctx)}

  # A skill runs as an ordinary turn: the agent is told to carry it out and reads it through
  # its own `skill` tool, which is what keeps community content marked untrusted. Behind a
  # running turn it waits its turn, like `/queue`.
  def run("skill", words, ctx) do
    [name | rest] = String.split(words, ~r/\s+/, parts: 2)

    case SkillCommands.find(name, skill_opts(ctx)) do
      {:ok, %{name: skill}} ->
        turn = SkillCommands.instruction(skill, Enum.join(rest))
        if ctx.running?, do: {:queue, turn}, else: {:prompt, turn}

      :none ->
        {:reply, gettext("Unknown skill: %{name}", name: name)}
    end
  end

  def run("version", _args, _ctx), do: {:reply, "Pepe v" <> Pepe.Update.current()}

  ###
  ### pieces
  ###

  defp idle(%{running?: true}, _fun), do: wait()
  defp idle(_ctx, fun), do: fun.()

  # `idle/2` plus the session-must-exist step every command that touches the session needs.
  defp idle_ready(ctx, fun) do
    idle(ctx, fn ->
      with :ok <- ensure(ctx), do: fun.()
    end)
  end

  defp wait, do: {:reply, gettext("Wait for the current turn to finish.")}

  defp skills_text(ctx) do
    case SkillCommands.list(skill_opts(ctx)) do
      [] ->
        gettext("No skills are available yet.")

      skills ->
        gettext("Available skills (run with /skill <name>):") <> "\n" <> Enum.map_join(skills, "\n", &skill_line/1)
    end
  end

  defp skill_line(%{name: name, summary: summary, needs: needs}),
    do: "- #{name}: #{summary}" <> if(needs, do: " (#{needs})", else: "")

  # A session process is only started by a session's first message, so a command sent
  # before one (`/model` as the very first thing typed) has to start it.
  defp ensure(ctx) do
    case SessionSupervisor.ensure(ctx.key, ctx.agent) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:reply, "Error: could not start the session (#{inspect(reason)})"}
    end
  end

  defp retry_prompt(text, []), do: {:prompt, text}
  defp retry_prompt(text, lines), do: {:prompt, text, Enum.join(lines, "\n")}

  defp rewind(ctx, count, mode) do
    case Session.rewind_to(ctx.key, count, mode, roots: roots(ctx)) do
      {:ok, result} -> {:reply, "⏪ " <> Pepe.Checkpoints.Report.summary(result, requested: count, mode: mode)}
      {:error, :busy} -> wait()
    end
  end

  # The editor's working directory is a folder a rewind may put files back into, like an
  # agent's own workspace: its tools resolve there (see `cwd_override`), so that is where
  # their changes were recorded.
  defp roots(ctx), do: if(is_binary(ctx[:cwd]), do: [ctx.cwd], else: [])

  # An editor is one person's tool, so no "this conversation or everyone?" question: a
  # bare `/model NAME` is this conversation, and `global` is spelled out to get the other.
  defp change_model(ctx, name, scope) do
    if Config.get_model(name) do
      agent_name = Session.status(ctx.key).agent

      case ModelSwitch.apply(ctx.key, agent_name, name, scope) do
        :ok ->
          {:reply, gettext("Model set to %{name} (%{scope}).", name: name, scope: scope_label(scope))}

        {:error, :unknown_model} ->
          {:reply, gettext("Unknown model: %{name}", name: name)}

        {:error, :unknown_agent} ->
          {:reply, gettext("There's no agent to set the model on.")}
      end
    else
      {:reply, gettext("Unknown model: %{name}", name: name)}
    end
  end

  defp scope_label(:session), do: gettext("this conversation only")
  defp scope_label(:global), do: gettext("everyone")

  defp tools_text(key) do
    agent =
      case Pepe.Agent.resolve(Session.status(key).agent) do
        {:ok, agent} -> agent
        _ -> nil
      end

    names = if agent && is_list(agent.tools), do: Enum.sort(agent.tools), else: []

    case names do
      [] ->
        gettext("No tools are enabled for this agent.")

      names ->
        gettext("Available tools") <> "\n" <> Enum.map_join(names, "\n", &tool_line/1)
    end
  end

  defp tool_line(name) do
    case Pepe.Tools.summary(name) do
      "" -> "- #{name}"
      summary -> "- #{name}: #{summary}"
    end
  end

  # What is known about the context window: its size (from the model in force) and, once
  # a request has been made, how much of it the last one filled (what the provider
  # reported, not an estimate).
  defp context_lines(status, last_usage) do
    size = window_size(status[:model_name]) || (last_usage && last_usage.size)

    window =
      if size, do: [gettext("Context window: %{size} tokens", size: size)], else: []

    used =
      case {last_usage, size} do
        {%{used: used}, size} when is_integer(size) and size > 0 ->
          [gettext("Last request: ~%{used} tokens (%{pct}%)", used: used, pct: Float.round(used / size * 100, 1))]

        {%{used: used}, _} ->
          [gettext("Last request: ~%{used} tokens (%{pct}%)", used: used, pct: "?")]

        _ ->
          [gettext("No request has been made yet, so there is nothing to measure.")]
      end

    window ++ used
  end

  defp window_size(nil), do: nil

  defp window_size(name) do
    case Config.get_model(name) do
      nil -> nil
      model -> Compaction.window(model)
    end
  end

  defp help do
    lines =
      Enum.map_join(@commands, "\n", fn {name, description, hint} ->
        arg = if hint, do: " <#{hint}>", else: ""
        "/#{name}#{arg}: #{description}"
      end)

    gettext("Commands:") <> "\n" <> lines
  end
end
