defmodule Pepe.Eval.FromTrace do
  @moduledoc """
  Turn a conversation that already happened into a case that has to keep happening.

  Pepe records every run (`Pepe.Trace`) and can replay prompts against an agent
  (`Pepe.Eval`). The two never spoke to each other, and the gap between them is where agent
  products quietly rot: somebody edits a persona, grants a tool, swaps a model, and a
  behaviour that used to work stops working. Nothing crashes. No test fails, because nobody
  wrote a test for a thing the agent simply *did right* one afternoon. The customer finds out.

  So the traces are the test data. When an agent handles something well, promote that run:
  the prompt and the agent are copied verbatim, and what it did becomes the assertion.

  ## What gets asserted, and what does not

  **The tools it called.** This is the assertion worth having. It is stable across model
  updates and rewording, and it is what actually changes when a persona edit goes wrong: the
  agent stops looking things up and starts inventing them, or starts running a shell command
  where it used to read a file. A model that answers the same question with the same tools is
  a model that still works the way you decided it should.

  **Not the reply, word for word.** Two runs of the same prompt do not produce the same
  sentence, and a test that demands they do fails on Tuesday for no reason, gets muted, and
  from then on protects nothing. The reply that was right is kept in the case under
  `recorded`, as documentation for whoever reads a failure, and asserted on only where a
  human says so (`--contains`), because only a human knows which words in it were the point.
  """

  alias Pepe.Eval
  alias Pepe.Trace

  @doc """
  Build an eval case from a recorded trace.

  `opts`: `:name` (defaults to a label derived from the prompt), `:contains` (phrases the
  reply must keep carrying). Returns `{:ok, case}`, or `{:error, reason}` when the trace is
  gone or holds nothing worth replaying.
  """
  @spec build(String.t() | nil, String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(scope, id, opts \\ []) do
    with %{} = trace <- Trace.get(scope, id) || {:error, "no trace #{id}"},
         :ok <- refuse_failure(trace),
         {:ok, prompt} <- prompt_of(trace),
         {:ok, agent} <- agent_of(trace) do
      {:ok,
       %{
         "name" => opts[:name] || label(prompt),
         "agent" => agent,
         "prompt" => prompt,
         # Where this came from, so a failure can be read against the run that defined it.
         "from_trace" => id,
         "recorded" => reply_of(trace),
         "expect" => expect(trace, opts[:contains])
       }}
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Build a case from a trace and append it to a suite, writing the suite file.

  Refuses to add a second case for a trace already promoted: a suite that accumulates the
  same conversation four times is a suite nobody trusts the count of.
  """
  @spec promote(String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t() | :already_recorded}
  def promote(scope, id, suite, opts \\ []) do
    with {:ok, kase} <- build(scope, id, opts),
         :ok <- refuse_duplicate(suite, id) do
      write(suite, Eval.load(suite) ++ [kase])
      {:ok, kase}
    end
  end

  @doc "Whether the trace `id` has already been promoted into `suite` as a case."
  def already_case?(suite, id) do
    Enum.any?(Eval.load(suite), &(&1["from_trace"] == id))
  end

  defp refuse_duplicate(suite, id) do
    if already_case?(suite, id), do: {:error, :already_recorded}, else: :ok
  end

  defp write(suite, cases) do
    File.mkdir_p!(Eval.dir())
    path = Path.join(Eval.dir(), suite <> ".json")
    File.write!(path, Jason.encode_to_iodata!(cases, pretty: true))
    path
  end

  # A run that failed is not a thing to keep doing. Promoting one would freeze the failure
  # as the expectation and, worse, hand you a green suite for it.
  defp refuse_failure(%{"outcome" => %{"kind" => "error", "reason" => why}}),
    do: {:error, "that run failed (#{why}) - there is nothing there worth keeping"}

  defp refuse_failure(_), do: :ok

  defp prompt_of(%{"prompt" => p}) when is_binary(p) and p != "", do: {:ok, p}
  defp prompt_of(_), do: {:error, "that trace has no prompt to replay"}

  defp agent_of(%{"agent" => a}) when is_binary(a) and a != "", do: {:ok, a}
  defp agent_of(_), do: {:error, "that trace has no agent to replay it against"}

  # The tools it used, in the order it used them, deduplicated: `tool_called` asks whether
  # each ran, not how often, so the same tool twice adds nothing but noise to the file.
  defp expect(trace, contains) do
    tools =
      trace
      |> events()
      |> Enum.filter(&(&1["t"] == "tool_call"))
      |> Enum.map(& &1["name"])
      |> Enum.uniq()

    %{}
    |> put_unless_empty("tool_called", tools)
    |> put_unless_empty("contains", List.wrap(contains))
  end

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp reply_of(trace) do
    trace
    |> events()
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"t" => "done", "content" => c} when is_binary(c) -> c
      %{"t" => "assistant", "text" => t} when is_binary(t) -> t
      _ -> nil
    end)
  end

  defp events(%{"events" => events}) when is_list(events), do: events
  defp events(_), do: []

  # A case is found by name in a report, so the name has to read like the question.
  @label_len 60
  defp label(prompt) do
    prompt
    |> String.split("\n", trim: true)
    |> List.first("case")
    |> String.trim()
    |> String.slice(0, @label_len)
  end
end
