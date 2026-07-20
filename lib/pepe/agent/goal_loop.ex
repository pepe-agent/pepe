defmodule Pepe.Agent.GoalLoop do
  @moduledoc """
  Run an agent **toward a goal** instead of for one turn: given an objective and a
  *verifiable* success criterion, work, have an **independent judge** check the result
  against the criterion, and keep going until it passes or the attempt cap is hit.

  This is the loop *above* the turn loop. `Pepe.Agent.Runtime` loops until the model
  stops calling tools (one answer); this loops until the **outcome** is good:

      attempt -> work (Runtime, with tools) -> judge (fresh one-shot) -> pass? done : retry

  The judge is what makes it more than self-assessment: it's a separate call with a
  clean context that never sees the working conversation, only the criterion and the
  result, so it grades the artifact rather than re-reading its own reasoning. Give it a
  different model (`judge_model`) for real independence; it defaults to the agent's.

  Progress is written to the session's goal (`Pepe.Session.Focus`) as it runs -
  `criteria`, `attempt`, `max_attempts`, and the judge's last `verdict` - so any surface
  showing the goal shows the loop live. Terminal states: `complete` (judge passed) or
  `blocked` (cap reached, with what was still missing).

  The cap is mandatory: a criterion the agent can never satisfy must cost a bounded
  number of attempts, not run forever.
  """
  use Gettext, backend: Pepe.Gettext

  require Logger

  alias Pepe.Agent.Session
  alias Pepe.Config
  alias Pepe.LLM
  alias Pepe.LLM.Message
  alias Pepe.Session.Focus

  @default_attempts 3
  @max_attempts 10

  @type verdict :: %{met: boolean(), feedback: String.t()}
  @type result ::
          {:ok, :met, String.t(), pos_integer()}
          | {:error, :max_attempts, String.t(), String.t()}
          | {:error, term()}

  @doc """
  Pursue `objective` in session `key` until `criteria` is met.

  Options:
    * `:max_attempts` - how many work+judge rounds to allow (default #{@default_attempts},
      hard cap #{@max_attempts}).
    * `:judge_model` - the model connection the judge uses. Defaults to the agent's own
      model; a *different* one gives a more independent verdict.
    * `:on_event` - a callback for progress: `{:goal_attempt, n, max}` and
      `{:goal_verdict, met?, feedback}`.
    * any other option is passed through to `Session.chat/3` (e.g. `authorize`).

  Returns `{:ok, :met, final_answer, attempts_used}`, `{:error, :max_attempts,
  last_answer, missing}`, or `{:error, reason}`.
  """
  @spec run(term(), String.t(), String.t(), keyword()) :: result()
  def run(key, objective, criteria, opts \\ [])

  def run(_key, objective, _criteria, _opts) when not is_binary(objective) or objective == "",
    do: {:error, :no_objective}

  def run(_key, _objective, criteria, _opts) when not is_binary(criteria) or criteria == "",
    do: {:error, :no_criteria}

  def run(key, objective, criteria, opts) do
    # The work prompts below become *visible messages* in the conversation, so they must
    # be in the user's language. Gettext's locale is per-process and this runs in a
    # spawned one, so apply the configured locale here rather than inheriting it.
    Config.put_locale()

    max = opts |> Keyword.get(:max_attempts, @default_attempts) |> clamp()

    Focus.put_goal(key, %{
      "objective" => objective,
      "criteria" => criteria,
      "status" => "active",
      "attempt" => 0,
      "max_attempts" => max,
      "at" => System.os_time(:second)
    })

    attempt(key, objective, criteria, nil, 1, max, opts)
  end

  # --- the loop ---------------------------------------------------------------------

  # `feedback` is nil on the first attempt and the judge's complaint on every retry. The
  # objective stays untouched throughout: the judge must always grade against the
  # original goal, never against a retry instruction.
  defp attempt(key, objective, criteria, feedback, n, max, opts) do
    emit(opts, {:goal_attempt, n, max})
    track(key, &Map.put(&1, "attempt", n))

    case Session.chat(key, work_prompt(objective, criteria, feedback), chat_opts(opts)) do
      {:ok, answer} ->
        judge_answer(key, objective, criteria, answer, n, max, opts)

      {:error, reason} ->
        track(key, &(&1 |> Map.put("status", "blocked") |> Map.put("verdict", "run failed: #{inspect(reason)}")))
        {:error, reason}
    end
  end

  defp judge_answer(key, objective, criteria, answer, n, max, opts) do
    %{met: met?, feedback: feedback} = judge(key, objective, criteria, answer, opts)
    emit(opts, {:goal_verdict, met?, feedback})

    cond do
      met? ->
        track(key, &(&1 |> Map.put("status", "complete") |> Map.put("verdict", feedback)))
        Logger.info("[goal] met after #{n} attempt(s)")
        {:ok, :met, answer, n}

      n >= max ->
        track(key, &(&1 |> Map.put("status", "blocked") |> Map.put("verdict", feedback)))
        Logger.info("[goal] gave up after #{n} attempt(s): #{feedback}")
        {:error, :max_attempts, answer, feedback}

      true ->
        track(key, &Map.put(&1, "verdict", feedback))
        attempt(key, objective, criteria, feedback, n + 1, max, opts)
    end
  end

  # --- prompts ----------------------------------------------------------------------

  # First attempt states the goal and how it will be checked; later ones carry only the
  # judge's complaint, so the agent fixes what actually failed instead of restarting.
  defp work_prompt(_objective, _criteria, feedback) when is_binary(feedback) and feedback != "" do
    gettext(
      """
      That did not meet the success criterion yet. An independent reviewer said:

      %{feedback}

      Address exactly that and produce the corrected result.
      """,
      feedback: feedback
    )
  end

  defp work_prompt(objective, criteria, _feedback) do
    gettext(
      """
      %{objective}

      This will be checked against the following success criterion, so make sure your
      final answer satisfies it:

      %{criteria}
      """,
      objective: objective,
      criteria: criteria
    )
  end

  # The judge never sees the working conversation - only the criterion and the result.
  # That's the independence: it grades the artifact, not the reasoning that produced it.
  defp judge(key, objective, criteria, answer, opts) do
    model = judge_model(key, opts)

    prompt = """
    You are an impartial reviewer. Decide ONLY whether the result below meets the
    success criterion. Do not be generous: if any part of the criterion is unmet,
    it fails.

    OBJECTIVE:
    #{objective}

    SUCCESS CRITERION:
    #{criteria}

    RESULT TO REVIEW:
    #{answer}

    Reply with JSON only: {"met": true|false, "feedback": "..."}
    When met, `feedback` states briefly why it passes. When not met, `feedback` says
    exactly what is missing or wrong, so it can be fixed.
    """

    case LLM.chat(model, [Message.system("You grade results against a criterion. Reply with JSON only."), Message.user(prompt)],
           max_tokens: 500
         ) do
      {:ok, %{content: content} = result} when is_binary(content) ->
        meter(key, model, result[:usage])
        parse_verdict(content)

      other ->
        %{met: false, feedback: "the reviewer could not be reached (#{inspect(other)})"}
    end
  end

  # The judge is a real, separately-billed model call - meter it the same as any other, so
  # it doesn't silently vanish from spend the way an aux-model call that nobody thought to
  # meter would.
  defp meter(key, model, usage) when is_map(usage), do: Pepe.Usage.record(agent_name(key), model, usage)
  defp meter(_key, _model, _usage), do: :ok

  defp agent_name(key) do
    case Session.status(key) do
      %{agent: agent} when is_binary(agent) -> agent
      _ -> "unknown"
    end
  end

  # A judge that answers unreadably is treated as "not met" on purpose: passing on an
  # unparseable verdict would let a bad result through, which is the one thing this
  # loop exists to prevent.
  defp parse_verdict(content) do
    with {:ok, json} <- extract_json(content),
         %{"met" => met} = map when is_boolean(met) <- json do
      %{met: met, feedback: to_string(map["feedback"] || "")}
    else
      _ -> %{met: false, feedback: "the reviewer's verdict was unreadable: #{String.slice(content, 0, 200)}"}
    end
  end

  # Models like to wrap JSON in prose or fences; take the first {...} block.
  defp extract_json(content) do
    case Regex.run(~r/\{.*\}/s, content) do
      [json] -> Jason.decode(json)
      _ -> :error
    end
  end

  defp judge_model(key, opts) do
    case opts[:judge_model] do
      name when is_binary(name) and name != "" -> Config.get_model(name) || agent_model(key)
      _ -> agent_model(key)
    end
  end

  defp agent_model(key) do
    case Session.status(key) do
      %{agent: agent} when is_binary(agent) -> Config.model_for_agent(Config.get_agent(agent))
      _ -> Config.default_model()
    end
  end

  # --- helpers ----------------------------------------------------------------------

  # The judge and the goal bookkeeping are ours; everything else (authorize, streaming)
  # belongs to the caller's turn.
  defp chat_opts(opts), do: Keyword.drop(opts, [:max_attempts, :judge_model])

  defp track(key, fun) do
    case Focus.get_goal(key) do
      nil -> :ok
      goal -> Focus.put_goal(key, fun.(goal))
    end
  end

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_attempts)
  defp clamp(_), do: @default_attempts

  defp emit(opts, event) do
    case opts[:on_event] do
      fun when is_function(fun, 1) -> fun.(event)
      _ -> :ok
    end
  end
end
