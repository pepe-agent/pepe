defmodule Pepe.Decide do
  @moduledoc """
  "Which of these?": the one place Pepe asks a model to pick among a few named options. Two
  callers use it today, the complexity triage and the mid-turn message check, and both used
  to carry their own copy of the same dance (call a cheap chat model with a one-word prompt,
  read the word, meter the call, bound the wait).

  The question is given once, in two forms: `chat_system`/`chat_user` for an ordinary chat
  model, which answers with a word, and `instructions`/`criteria` for a decision connection
  (`Pepe.Decide.Jev`), which answers with an option and a confidence. `choose/3` takes a chain
  of connections (see `chain/1`) and works down it:

    * a connection that fails (no credit, a bad key, down, slow) is skipped, and a decision
      connection is also left alone for a while (`Pepe.LLM.Cooldown`) so a message does not
      pay for a failed call every time;
    * an answer for the risky option (the one that is not `default`) with a confidence below
      `min_confidence` is not trusted either: the next connection in the chain, a normal
      model, is asked instead. An answer for the safe option is accepted whatever the
      confidence, since being wrong that way costs nothing;
    * when nobody in the chain answers, the safe `default` wins.

  It always returns something, so a caller never has to handle a failed decision.
  """

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Decide.Jev
  alias Pepe.LLM
  alias Pepe.LLM.Cooldown
  alias Pepe.LLM.Message

  @type question :: %{
          state: String.t(),
          instructions: String.t(),
          criteria: %{String.t() => String.t()},
          default: String.t() | nil,
          min_confidence: float(),
          chat_system: String.t(),
          chat_user: String.t()
        }

  @type decision :: %{choice: String.t() | nil, via: String.t() | nil, confidence: float() | nil}

  @doc """
  The decision connection an agent may ask directly (the `decide` tool), followed by its own
  fallbacks: the agent's `triage_model` when that is a decision connection, otherwise the first
  decision connection in the agent's project. `[]` when there is none, which is also what keeps
  the tool from being offered.
  """
  @spec connections_for(map() | nil) :: [Model.t()]
  def connections_for(%{name: name} = agent) when is_binary(name) do
    own = agent |> Map.get(:triage_model) |> chain_names()

    primary =
      Enum.find(own, &Model.decision?/1) ||
        Enum.find(Enum.sort_by(Config.models(), & &1.name), &(Model.decision?(&1) and Pepe.Project.same_scope?(&1.name, name)))

    case primary do
      nil -> []
      %Model{} = model -> chain([model.name])
    end
  end

  def connections_for(_agent), do: []

  defp chain_names(nil), do: []
  defp chain_names(name), do: chain([name])

  @doc """
  The connections to try, in order: each name followed by its own `fallbacks`, names that no
  longer exist dropped, duplicates removed. `nil` entries are ignored, so a caller can pass
  an optional name as is.
  """
  @spec chain([String.t() | nil]) :: [Model.t()]
  def chain(names) do
    names
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn name ->
      case Config.get_model(name) do
        nil -> []
        %Model{} = model -> [model | Enum.flat_map(model.fallbacks || [], &List.wrap(Config.get_model(&1)))]
      end
    end)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Decide. `confidence` is the decision model's own (`nil` from a chat model). `via` is the connection that answered, or `nil` when none did and `default` is
  only the safe fallback (`nil` itself for an open question, where nobody answering is just
  "no decision"). Usage of every answered call is metered against `agent_name`.
  """
  @spec choose([Model.t()], question(), String.t()) :: decision()
  def choose(chain, question, agent_name) do
    chain
    |> Enum.reject(&(Model.decision?(&1) and Cooldown.cooling_down?(&1)))
    |> try_each(question, agent_name)
  end

  defp try_each([], question, _agent_name), do: %{choice: question.default, via: nil, confidence: nil}

  defp try_each([model | rest], question, agent_name) do
    case ask(model, question) do
      {:ok, choice, confidence, usage} ->
        if Model.decision?(model), do: Cooldown.clear(model)
        meter(agent_name, model, usage)

        if trusted?(choice, confidence, question),
          do: %{choice: choice, via: model.name, confidence: confidence},
          else: try_each(rest, question, agent_name)

      {:error, reason} ->
        # Only a decision connection is put on pause: a chat model also serves conversations,
        # and one failed triage call must not take it out of their failover chains.
        if Model.decision?(model), do: Cooldown.mark_failed(model, reason)
        try_each(rest, question, agent_name)
    end
  end

  defp trusted?(choice, _confidence, %{default: choice}), do: true
  defp trusted?(_choice, nil, _question), do: true
  defp trusted?(_choice, confidence, %{min_confidence: min}), do: confidence >= min

  defp ask(%Model{} = model, question) do
    if Model.decision?(model), do: Jev.decide(model, question), else: ask_chat(model, question)
  end

  # The chat-model way: a fixed prompt, one word back. Anything that is not the word of the
  # risky option reads as the safe default, same as before this module existed.
  defp ask_chat(model, question) do
    case LLM.chat(model, [Message.system(question.chat_system), Message.user(question.chat_user)]) do
      {:ok, %{content: content} = result} ->
        case word(content, question) do
          nil -> {:error, :no_option_in_reply}
          choice -> {:ok, choice, nil, result[:usage]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # The option the reply names: an exact match first ("SIMPLE", "complex."), then the longest
  # option name found inside it (longest first, so "urgent" is not read out of "not urgent"
  # before "not urgent" itself is tried). Nothing named reads as the safe `default`.
  defp word(content, question) do
    reply = content |> to_string() |> String.trim() |> String.trim(".") |> String.upcase()
    options = question.criteria |> Map.keys() |> Enum.reject(&(&1 == question.default))

    Enum.find(options, &(String.upcase(&1) == reply)) ||
      options
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.find(question.default, &(reply =~ String.upcase(&1)))
  end

  # A decision is a real, separately billed call: it counts toward the operator's spend like
  # the main turn does.
  defp meter(agent_name, model, usage) when is_map(usage), do: Pepe.Usage.record(agent_name, model, usage)
  defp meter(_agent_name, _model, _usage), do: :ok
end
