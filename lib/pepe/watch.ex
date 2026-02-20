defmodule Pepe.Watch do
  @moduledoc """
  The evaluation engine for one-shot "notify me when X" watches
  (`Pepe.Config.Watch`).

  A watch is re-checked on a timer. The **trigger** is the cheap part that runs every
  interval; only when it fires does the (possibly expensive) **on_fire** run, once:

    * a `probe` trigger runs a shell command — no LLM per check;
    * an `agent` trigger re-asks the agent (one LLM call per check) for conditions that
      need judgement.

  `evaluate/1` performs one check of a due watch and returns the updated struct plus
  the notification text to deliver (or `nil`). The scheduler persists the struct and
  routes delivery; this module holds the pure decision logic + the check/fire effects.
  """

  alias Pepe.Config.Watch

  # The agent-trigger contract: the reply tells us whether the condition is met.
  @fired "WATCH_FIRED"
  @wait "WATCH_WAIT"

  @doc "Is this watch due for a check right now (`now` = unix seconds)?"
  @spec due?(Watch.t(), integer()) :: boolean()
  def due?(%Watch{state: "pending", next_check: nil}, _now), do: true
  def due?(%Watch{state: "pending", next_check: n}, now) when is_integer(n), do: now >= n
  def due?(_watch, _now), do: false

  @doc """
  Run one check of a due watch. Returns `{updated_watch, delivery_text | nil}`:
  fired → state `done` + the text to send; still waiting → bumped counters; hit
  `max_checks` → state `expired`.
  """
  @spec evaluate(Watch.t()) :: {Watch.t(), String.t() | nil}
  def evaluate(%Watch{} = w) do
    now = System.system_time(:second)
    w = %{w | checks: w.checks + 1, last_check: now, next_check: now + w.interval_s}

    case run_check(w) do
      :fired ->
        case fire_text(w) do
          {:ok, text} ->
            {%{w | state: "done", next_check: nil, last_error: nil}, text}

          {:error, reason} ->
            {expire_or_keep(%{w | last_error: "on_fire: #{inspect(reason)}"}), nil}
        end

      :waiting ->
        {expire_or_keep(%{w | last_error: nil}), nil}

      {:error, reason} ->
        {expire_or_keep(%{w | last_error: to_string(reason)}), nil}
    end
  end

  # Out of budget → stop watching (expired); otherwise keep waiting.
  defp expire_or_keep(%Watch{checks: c, max_checks: max} = w) when c >= max,
    do: %{w | state: "expired", next_check: nil}

  defp expire_or_keep(w), do: w

  ###
  ### trigger — is the condition met?
  ###

  defp run_check(%Watch{trigger: %{"type" => "probe"} = t}) do
    case run_command(t["command"]) do
      {out, code} -> if probe_success?(t["success"], out, code), do: :fired, else: :waiting
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_check(%Watch{trigger: %{"type" => "agent", "prompt" => prompt}, agent: agent}) do
    contract =
      "This is an automatic condition check — the user does not see it. Reply with " <>
        "EXACTLY `#{@fired}` if the condition is now satisfied, or `#{@wait}` if it is " <>
        "not yet. Nothing else."

    case Pepe.Agent.oneshot(agent, prompt <> "\n\n" <> contract) do
      {:ok, reply, _msgs} -> if fired?(reply), do: :fired, else: :waiting
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp run_check(_watch), do: {:error, "invalid trigger"}

  defp run_command(command) when is_binary(command) do
    System.cmd("sh", ["-c", command], stderr_to_stdout: true)
  end

  defp run_command(_), do: raise(ArgumentError, "probe has no command")

  # Default success is exit 0; `%{"contains" => s}` matches stdout instead.
  defp probe_success?(%{"contains" => s}, out, _code), do: String.contains?(out, s)
  defp probe_success?(_success, _out, code), do: code == 0

  defp fired?(reply) do
    up = reply |> to_string() |> String.upcase()
    String.contains?(up, @fired) and not String.contains?(up, @wait)
  end

  ###
  ### on_fire — the message to send
  ###

  defp fire_text(%Watch{on_fire: %{"type" => "template", "text" => text}}) when is_binary(text),
    do: {:ok, text}

  defp fire_text(%Watch{on_fire: %{"type" => "agent", "prompt" => prompt}, agent: agent}) do
    case Pepe.Agent.oneshot(agent, prompt) do
      {:ok, reply, _msgs} -> {:ok, reply}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fire_text(%Watch{description: d}), do: {:ok, "✅ #{d || "watch"} — condition met."}
end
