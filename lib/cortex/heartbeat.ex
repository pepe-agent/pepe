defmodule Cortex.Heartbeat do
  @moduledoc """
  The proactive engine: periodically give a session's agent the floor to say
  something **on its own initiative** — and the right to say nothing.

  A pulse runs the same reply path as a real turn, but the prompt makes clear this
  is an automatic check and instructs the agent to answer with exactly the sentinel
  `HEARTBEAT_OK` when nothing is worth surfacing. Most pulses are silent; that's the
  point — it's what keeps a 24/7 agent from being spammy.

  Three things feed a pulse:

    * **System events** (`Cortex.Heartbeat.Events`) — short notes any subsystem can
      queue for a session (a background command finished, a cron fired, …).
    * **`HEARTBEAT.md`** — an optional file in the agent's workspace telling it what
      to watch for and how proactive to be. No file → the agent still gets a pulse
      but with no special brief (it can only act on system events + its own
      judgment).
    * **The cooldown gate** (`Cortex.Heartbeat.Cooldown`) — min-spacing + a flood
      breaker, checked before the pulse runs at all.

  `pulse/1` runs one check for a session. `active_hours?/2` and the caller decide
  *when* to call it — Cortex doesn't hardcode a scheduler here; each surface (e.g.
  the Telegram gateway) drives its own timer and calls `pulse/1` for sessions that
  opted in.
  """

  @sentinel "HEARTBEAT_OK"

  @doc """
  Run one pulse for `session_key`. Returns `{:ok, text}` when the agent chose to
  speak (already appended to the session's history), `:silent`, `{:defer, reason}`
  when the cooldown gate blocked it, or `{:error, reason}`.
  """
  @spec pulse(String.t()) :: {:ok, String.t()} | :silent | {:defer, atom()} | {:error, term()}
  def pulse(session_key) do
    case Cortex.Heartbeat.Cooldown.allow?(session_key) do
      :ok -> Cortex.Agent.Session.heartbeat(session_key)
      {:defer, reason} -> {:defer, reason}
    end
  end

  @doc """
  Was `reply` the silence sentinel? Models routinely wrap a bare token in stray
  formatting — `*HEARTBEAT_OK*`, `"HEARTBEAT_OK"`, `HEARTBEAT_OK!!!`, `.HEARTBEAT_OK`.
  Match the exact token first, then retry after stripping edge whitespace and
  surrounding punctuation, so those all still count as "stay silent" while the token
  embedded in real prose does not.
  """
  @spec silent?(String.t()) :: boolean()
  def silent?(reply) do
    text = reply |> to_string() |> String.trim() |> String.upcase()
    text == @sentinel or strip_edge_punctuation(text) == @sentinel
  end

  # Drop leading/trailing Unicode punctuation (and any whitespace it exposes).
  defp strip_edge_punctuation(text) do
    text
    |> String.replace(~r/^[\p{P}\s]+|[\p{P}\s]+$/u, "")
  end

  @doc "Build the internal pulse prompt: brief + pending system events + the sentinel contract."
  @spec build_prompt(String.t(), String.t()) :: String.t()
  def build_prompt(session_key, agent_name) do
    events = Cortex.Heartbeat.Events.take(session_key)

    [
      "[Automatic heartbeat check — the user does not see this prompt, only your reply if you choose to send one.]",
      brief(agent_name),
      events_block(events),
      "Decide, on your own, whether there's anything genuinely worth proactively telling the user right now (based on the events above, prior conversation, or anything you were asked to watch for). Most of the time there is nothing — that's expected and correct.",
      "If there's nothing worth saying, reply with EXACTLY: #{@sentinel}",
      "If there IS something worth saying, write that message directly — it will be sent to the user as-is."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp brief(agent_name) do
    path = Path.join(Cortex.Agent.Workspace.dir(agent_name), "HEARTBEAT.md")

    case File.read(path) do
      {:ok, content} -> "What to watch for (HEARTBEAT.md):\n" <> String.trim(content)
      _ -> nil
    end
  end

  defp events_block([]), do: nil

  defp events_block(events) do
    "Pending system events since the last check:\n" <> Enum.map_join(events, "\n", &"- #{&1}")
  end

  @doc """
  Is `hour` (0-23, in whatever timezone the caller resolved) inside the given
  `[start, finish)` active window? Permissive on a nonsensical window (start >=
  finish, or no window given) — always active, so a config mistake never silences a
  heartbeat that's actually wanted.
  """
  @spec active_hours?(nil | [integer()], integer()) :: boolean()
  def active_hours?(nil, _hour), do: true

  def active_hours?([start, finish], hour) when start < finish,
    do: hour >= start and hour < finish

  def active_hours?(_window, _hour), do: true
end
