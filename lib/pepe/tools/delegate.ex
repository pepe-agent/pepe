defmodule Pepe.Tools.Delegate do
  @moduledoc """
  Hand several pieces of work to fresh copies of yourself, at the same time, and get back
  only the answers.

  "Compare these eight competitors" is not one task, it is eight, and doing them in one
  conversation costs twice over: it takes eight times as long, and every page fetched for
  competitor one is still sitting in the context window while the model reads about
  competitor eight. The window fills with material nobody will look at again, and the
  quality of the final answer falls as it does.

  A delegated worker is a throwaway: a fresh run, its own context window, its own trace. It
  reads what it needs, answers the question it was given, and disappears. The parent gets
  the answers and never sees the eight transcripts, so a task that could not have fitted in
  one window fits now. They run together, so it takes as long as the slowest one.

  ## A worker may read; it may not act

  A worker inherits only the tools that need no permission: reading files, listing
  directories, fetching a URL, searching the web. Anything that writes, executes, installs
  or deletes is dropped before the worker starts.

  This is deliberate, and it is not a limitation to be worked around later. Three workers
  running at once are three workers that would want to ask the human three questions at
  once, and the answer to "may I run this?" is not a thing to be asked in triplicate. More
  fundamentally, fan-out is for *finding out*, and finding out is safe to do in parallel;
  *acting* is not, and it stays where it belongs, in the one conversation the human is
  actually watching. A worker that discovers something needs doing says so, and the parent
  does it, at the gate, in front of you.

  Workers also cannot delegate. Without that, one task becomes eight becomes sixty-four,
  and the bill arrives before the answer does.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Permissions

  # Enough for a real fan-out, few enough that a confused model cannot spend your month in
  # one call. The model is told the limit, so it splits the work rather than being surprised.
  @max_tasks 8

  # A worker is a side quest, not a life's work. It answers or it gives up.
  @timeout_ms 180_000

  @impl true
  def name, do: "delegate"

  @impl true
  def spec do
    function(
      "delegate",
      """
      Run several independent pieces of research at the same time, each in its own fresh \
      context, and get back their answers. Use it when a task splits cleanly into parts that \
      do not depend on each other (compare N things, check N sources, summarize N documents) \
      and you would otherwise do them one after another and fill your context with material \
      you only need once.

      Each task must be self-contained: the worker sees only the sentence you give it, not \
      this conversation. Say what to find out and what to hand back.

      Workers can read files, list directories, fetch URLs and search the web. They cannot \
      write, run commands, install anything or delegate further. If a task needs something \
      done rather than found out, do it yourself afterwards.

      Up to #{@max_tasks} tasks per call.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "tasks" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "One self-contained instruction per worker."
          },
          "agent" => %{
            "type" => "string",
            "description" => "Optional: run the workers as this agent instead of yourself. It must be one you're allowed to message."
          }
        },
        "required" => ["tasks"]
      }
    )
  end

  # Every worker is a network-bound wait, and they do not touch each other: this is exactly
  # the shape parallel tool execution exists for.
  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"tasks" => tasks} = args, ctx) when is_list(tasks) do
    tasks = tasks |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == ""))

    cond do
      tasks == [] ->
        {:error, "delegate needs at least one task"}

      length(tasks) > @max_tasks ->
        {:error, "too many tasks (#{length(tasks)}); #{@max_tasks} at most - split the work"}

      true ->
        dispatch(tasks, args["agent"], ctx)
    end
  end

  def run(_args, _ctx), do: {:error, "delegate needs `tasks` (a list of instructions)"}

  defp dispatch(tasks, as_agent, ctx) do
    case worker(as_agent, ctx) do
      {:ok, worker} -> {:ok, fan_out(tasks, worker, ctx)}
      {:error, _} = error -> error
    end
  end

  # The worker: this agent (or a peer it may message), stripped of everything that acts.
  defp worker(as_agent, ctx) do
    with %{} = parent <- ctx[:agent] || {:error, "no calling agent in context"},
         {:ok, base} <- resolve(parent, as_agent) do
      {:ok, %{base | tools: readable(base.tools)}}
    end
  end

  defp resolve(parent, name) when is_binary(name) and name != "", do: peer(parent, name)
  defp resolve(parent, _name), do: {:ok, parent}

  # Delegating *as* another agent reuses the same directed allowlist that governs messaging
  # one, rather than inventing a second, weaker authority for the same act.
  defp peer(parent, name) do
    cond do
      name not in (parent.can_message || []) ->
        {:error, "Agent #{name} isn't available to you."}

      is_nil(Config.get_agent(name)) ->
        {:error, "Unknown agent: #{name}"}

      true ->
        {:ok, Config.get_agent(name)}
    end
  end

  # Only what needs no permission - and never `delegate` itself, or one task becomes sixty-four.
  # A worker researches: it reads files and the web and reports back. It does not act, and it
  # does not speak for the parent to anyone else. So the approval-gated tools go (it holds no
  # `authorize` to answer them), `delegate` goes (no nesting), and `send_to_agent` goes too —
  # that one is always-safe, so the approval filter would leave it in, and a worker that read a
  # malicious document could then route that instruction to a peer that *does* act, laundering
  # the whole read-only guarantee in one hop.
  defp readable(tools) do
    tools
    |> List.wrap()
    |> Enum.reject(&(Permissions.requires_approval?(&1) or &1 in ~w(delegate send_to_agent)))
  end

  defp fan_out(tasks, worker, ctx) do
    tasks
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {task, i} -> {i, task, answer(worker, task, ctx)} end,
      ordered: true,
      timeout: @timeout_ms + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(Enum.with_index(tasks, 1))
    |> Enum.map_join("\n\n", &render/1)
  end

  defp answer(worker, task, ctx) do
    # No `authorize`: a worker holds no tool that could ask for it. Its cwd is the parent's,
    # so relative paths mean the same thing they meant in the conversation that spawned it.
    # The taint travels with the task: if the parent has read a stranger's content, the task it
    # is handing down is that content, and the worker must start locked down too.
    opts = [
      cwd: ctx[:cwd],
      source: "delegate",
      session_key: nil,
      untrusted: Pepe.Permissions.tainted?(ctx)
    ]

    case Runtime.converse(worker, task, opts) do
      {:ok, reply, _messages} -> reply
      {:error, reason} -> "(failed: #{inspect(reason)})"
    end
  end

  # A worker that dies or runs out of time is reported as itself, not as a silence. The
  # parent can then say what it could not find out, which is a true answer; a missing section
  # would have been read as an empty one.
  defp render({{:ok, {i, task, reply}}, _}), do: "### #{i}. #{task}\n#{reply}"

  defp render({{:exit, :timeout}, {task, i}}),
    do: "### #{i}. #{task}\n(gave up: took longer than #{div(@timeout_ms, 1000)}s)"

  defp render({{:exit, reason}, {task, i}}), do: "### #{i}. #{task}\n(failed: #{inspect(reason)})"
end
