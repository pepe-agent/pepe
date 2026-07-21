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

  ## Waiting is the default; `background: true` is the escape hatch

  A normal call blocks the turn until every worker answers or times out - fine for a
  handful of quick lookups, but a genuinely slow fan-out (a dozen pages to read, a
  worker that itself has real thinking to do) leaves the conversation silent for
  minutes with nothing to show for it. `background: true` dispatches the same fan-out
  without waiting: the call returns immediately with an acknowledgment, so the model
  can keep working or tell the user it's on it, and the results arrive later as an
  ordinary follow-up message in the same conversation - delivered by re-running this
  session with the results in hand, the exact mechanism an agent's own promise-to-
  follow-up already uses (`Pepe.Commitments.Scheduler`), so the reply reaches whatever
  channel the conversation is already on with no new delivery code. Only available
  inside a real conversation: a background worker needs a session to report back to,
  so a one-shot run (`mix pepe run`, the HTTP API's oneshot form) refuses it outright
  rather than silently dropping the results nobody could ever receive.
  """

  @behaviour Pepe.Tools.Tool

  require Logger

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Runtime
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
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

      By default this waits for every worker and returns their answers. Set "background": \
      true to dispatch without waiting instead - the call returns right away with an \
      acknowledgment, and the results arrive later as a follow-up message in this same \
      conversation. Use that for a fan-out slow enough that waiting would leave the user \
      looking at silence; keep waiting for anything that answers in a few seconds. Only \
      works inside a real conversation, not a one-shot run.

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
          },
          "background" => %{
            "type" => "boolean",
            "description" => "Dispatch without waiting; results arrive as a follow-up message. Default false."
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

      args["background"] == true ->
        dispatch_background(tasks, args["agent"], ctx)

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

  # A worker needs no session (it never speaks for itself to anyone), but delivering its
  # results back *later* does - that is the whole difference from the synchronous path.
  defp dispatch_background(tasks, as_agent, ctx) do
    with {:ok, session_key} <- require_session(ctx),
         {:ok, worker} <- worker(as_agent, ctx) do
      agent_name = ctx.agent.name

      Task.start(fn ->
        results = fan_out(tasks, worker, ctx)
        deliver_background_results(session_key, agent_name, results)
      end)

      {:ok,
       "Dispatched #{length(tasks)} background task(s) - a follow-up message with the " <>
         "results will arrive in this conversation once they're all done. Keep going now, " <>
         "or answer the user without waiting for them."}
    end
  end

  defp require_session(%{session_key: key}) when is_binary(key), do: {:ok, key}

  defp require_session(_ctx),
    do: {:error, "background delegation needs a real conversation to report the results back to - use it without `background` here"}

  # Re-runs the session with the results in hand, the same delivery mechanism an agent's own
  # promise-to-follow-up already uses (Pepe.Commitments.Scheduler) - the agent's own reply then
  # reaches whatever channel the conversation is already on, no new delivery code needed. If the
  # session is gone (a `/new`, the process crashed) the results are simply lost - the same
  # tolerance the rest of this codebase already has for a fired watch or commitment landing on a
  # conversation that no longer exists.
  defp deliver_background_results(session_key, agent_name, results) do
    prompt = """
    The background research you dispatched just finished. Here's what came back:

    #{results}

    Reply to the user with what you found - a real answer, not just "done".
    """

    case SessionSupervisor.ensure(session_key, agent_name) do
      {:ok, _pid} ->
        # untrusted: true - the results are workers' own fetch_url/web_search output, the
        # same outside content that taints the synchronous path (see Runtime's
        # @outside_content). This turn opens WITH that content already in hand, not by
        # calling a tool for it, so it must start tainted rather than earn it mid-turn.
        case Session.chat(session_key, prompt, untrusted: true) do
          {:ok, _reply} -> :ok
          {:error, reason} -> Logger.warning("[delegate] background results couldn't be delivered to #{session_key}: #{inspect(reason)}")
        end

      _ ->
        Logger.warning("[delegate] background results dropped: session #{session_key} is gone")
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
