defmodule Pepe.Agent.CommitmentExtract do
  @moduledoc """
  After a turn ends, notices a stated follow-up in the last exchange - the user asking
  to be reminded of something, or the agent promising to check on something - and tracks
  it without anyone having to call a tool in the moment. Opt-in per agent (see
  `Pepe.Config.Agent.commitments`), and inert without a `utility_model` configured: same
  restraint `Pepe.Agent.SessionTitles` shows, this never falls back to the agent's own
  (expensive) model.

  Two-stage, so an ordinary turn (no follow-up implied) costs nothing: a free lexical
  pre-filter decides whether the turn is even worth a model call, gated on *time*
  reference words rather than promise phrasing - a genuine commitment essentially always
  carries one ("tomorrow", "sexta", "next week"), and that vocabulary is small and far
  less ambiguous across languages than "I'll"/"vou" style phrasing would be.

  A found commitment still isn't trusted outright: its `source_excerpt` must be a real
  substring of the turn's own messages (the cheap, mechanical half of the
  anti-hallucination gate - a fabricated quote is discarded before it ever reaches
  storage) and a fixed confidence threshold decides whether it's auto-scheduled or needs
  a human's own "yes, track that" first. See `Pepe.Config.Commitment` for what happens
  next (the scheduler, and why "who made the promise" changes how it's delivered).
  """

  alias Pepe.Agent.Utility
  alias Pepe.Commitments.DueDate
  alias Pepe.Config
  alias Pepe.Config.Commitment
  alias Pepe.LLM
  alias Pepe.LLM.Message
  alias Pepe.Usage
  alias Pepe.Watch.Delivery

  # Small models spend budget on hidden thinking before answering; too tight a cap and
  # the call returns nothing instead of the JSON asked for.
  @max_tokens 512
  @confidence_threshold 0.7

  # A small, enumerable set of time-referring words across en/pt/es. A pre-filter on
  # *these*, not on promise verbs ("I'll"/"vou"), because commitments worth tracking
  # essentially always carry one, and this vocabulary is far smaller and less ambiguous.
  @temporal_lexemes ~w(
    today tomorrow tonight morning afternoon evening
    hoje amanhã amanha manhã manha tarde noite
    hoy mañana manana
    monday tuesday wednesday thursday friday saturday sunday
    segunda terça terca quarta quinta sexta sábado sabado domingo
    lunes martes miércoles miercoles jueves viernes
    week weeks day days semana semanas dia dias día días
    next próxima proxima próximo proximo
  )

  @temporal_regex Regex.compile!("\\b(#{Enum.join(@temporal_lexemes, "|")})\\b", "iu")

  @instruction """
  You read the last exchange of a conversation looking for ONE thing: a follow-up someone
  implied, not just anything mentioned. Either the assistant promised to do something
  later ("let me check and I'll tell you tomorrow"), or the user asked to be reminded or
  notified of something ("me lembra de mandar o relatório sexta").

  Reply with strict JSON, nothing else, no markdown fences:
  {"commitment": true|false, "who": "user"|"agent", "text": "...", "source_excerpt": "...",
   "due_when": "...", "confidence": 0.0-1.0}

  - "commitment": false if nothing was actually promised or asked to be tracked - a plain
    statement about the future ("I'll be in São Paulo next week") is not a commitment.
  - "who": "agent" if the assistant made the promise, "user" if the user asked to be
    reminded/notified.
  - "text": a short third-person description of what's owed ("check the deploy and report
    back", "send the user the report").
  - "source_excerpt": the exact sentence this came from, copied verbatim from the
    conversation shown to you - never paraphrased, never invented.
  - "due_when": the relative time phrase as it was actually said ("tomorrow", "sexta",
    "in 2 weeks"), in whatever language it was said in. Never compute a date yourself.
  - "confidence": how sure you are this is a genuine commitment, not small talk.
  """

  @doc "Best-effort: notices a commitment in the turn's last exchange and stores it. Never raises, never blocks the turn (already running in its own Task by the time this is called)."
  def maybe_extract(%{key: key, agent_name: agent_name, messages: messages}) do
    {user_text, assistant_text} = last_exchange(messages)

    with %{commitments: true} = agent <- Config.get_agent(agent_name),
         model when not is_nil(model) <- Utility.model(agent),
         true <- has_temporal_reference?(user_text, assistant_text) do
      Task.start(fn -> extract_now(key, agent, model, user_text, assistant_text, messages) end)
    end

    :ok
  end

  def maybe_extract(_state), do: :ok

  defp last_exchange(messages) do
    reversed = Enum.reverse(messages)
    {content_of(Enum.find(reversed, &(&1["role"] == "user"))), content_of(Enum.find(reversed, &(&1["role"] == "assistant")))}
  end

  defp content_of(%{"content" => c}) when is_binary(c), do: c
  defp content_of(_), do: ""

  defp has_temporal_reference?(user_text, assistant_text),
    do: Regex.match?(@temporal_regex, user_text) or Regex.match?(@temporal_regex, assistant_text)

  defp extract_now(key, agent, model, user_text, assistant_text, messages) do
    prompt = build_prompt(user_text, assistant_text, open_commitment_texts(key))

    with {:ok, %{content: content} = result} when is_binary(content) <-
           LLM.chat(model, [Message.system(@instruction), Message.user(prompt)], max_tokens: @max_tokens, receive_timeout: 20_000),
         {:ok, parsed} <- extract_json(content),
         %{"commitment" => true} <- parsed,
         text when text != "" <- blank(parsed["text"]),
         excerpt when excerpt != "" <- blank(parsed["source_excerpt"]),
         true <- excerpt_in_transcript?(excerpt, messages) do
      meter(agent, model, result[:usage])
      store(key, agent, parsed, text, excerpt)
    else
      _ -> :ok
    end
  end

  defp open_commitment_texts(key) do
    Config.commitments()
    |> Enum.filter(&(&1.state in ["awaiting_confirmation", "scheduled"] and get_in(&1.origin, ["key"]) == key))
    |> Enum.map(& &1.text)
  end

  defp build_prompt(user_text, assistant_text, open) do
    open_line = if open == [], do: "", else: "\n\nAlready tracked for this conversation (don't repeat these): #{Enum.join(open, "; ")}"
    "#{today_line()}\n\nUser: #{user_text}\nAssistant: #{assistant_text}#{open_line}"
  end

  defp today_line do
    tz = Config.default_timezone()

    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, local} -> "Today is #{Calendar.strftime(local, "%A, %Y-%m-%d")} (#{tz})."
      _ -> "Today is #{Calendar.strftime(DateTime.utc_now(), "%A, %Y-%m-%d")} (UTC)."
    end
  end

  # Models like to wrap JSON in prose or fences; take the first {...} block.
  defp extract_json(content) do
    case Regex.run(~r/\{.*\}/s, content) do
      [json] -> Jason.decode(json)
      _ -> :error
    end
  end

  defp excerpt_in_transcript?(excerpt, messages) do
    needle = String.trim(excerpt)
    Enum.any?(messages, fn m -> is_binary(m["content"]) and String.contains?(m["content"], needle) end)
  end

  defp store(key, agent, parsed, text, excerpt) do
    origin_type = if parsed["who"] == "agent", do: "agent_promise", else: "user_reminder"
    confidence = confidence_of(parsed["confidence"])
    due_when = blank(parsed["due_when"])
    # Approximated against extraction time rather than the triggering message's own
    # timestamp: turn messages in this codebase don't carry one, and extraction runs
    # within the same request/response cycle the turn just finished in, so the gap is
    # negligible in practice. `blank/1` never returns nil (empty input becomes ""), and
    # DueDate.resolve/3 already treats "" the same as nil, so no extra guard is needed here.
    due_at = DueDate.resolve(due_when, System.system_time(:second))
    state = if is_nil(due_at) or confidence < @confidence_threshold, do: "awaiting_confirmation", else: "scheduled"

    commitment = %Commitment{
      text: text,
      source_excerpt: excerpt,
      due_when: due_when,
      due_at: due_at,
      origin_type: origin_type,
      agent: agent.name,
      origin: Delivery.origin_from_ctx(%{session_key: key}),
      confidence: confidence,
      state: state,
      created_at: System.system_time(:second)
    }

    case Config.create_commitment(commitment) do
      {:ok, %Commitment{state: "awaiting_confirmation"} = c} -> ask_confirmation(c)
      _ -> :ok
    end
  end

  # A commitment landing in review must not sit silently in a dashboard tab nobody
  # opens - a real one stuck there unnoticed is a *dropped* commitment, exactly the
  # failure this feature exists to prevent. One direct question, sent once, not a
  # repeated reminder.
  defp ask_confirmation(%Commitment{} = c) do
    when_text = c.due_when || "an unclear time"

    Delivery.deliver(
      c.origin,
      "Did you want me to remember this: \"#{c.text}\" (due #{when_text})? Say yes to confirm, or ignore to let it drop."
    )
  end

  defp confidence_of(c) when is_number(c), do: c |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
  defp confidence_of(_), do: 0.0

  defp blank(v) when is_binary(v), do: String.trim(v)
  defp blank(_), do: ""

  defp meter(%{name: agent_name}, model, usage) when is_map(usage), do: Usage.record(agent_name, model, usage)
  defp meter(_agent, _model, _usage), do: :ok
end
