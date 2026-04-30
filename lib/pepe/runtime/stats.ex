defmodule Pepe.Runtime.Stats do
  @moduledoc """
  What the runtime actually costs to run, measured live from the BEAM.

  "Lightweight by design" is the kind of claim that should be checkable rather than
  asserted, so the dashboard shows the real numbers: how much memory the node holds,
  how busy its schedulers are, how many conversations are alive, and what each agent's
  own sessions are holding.

  CPU comes from `:scheduler_wall_time`, which is a **cumulative counter**: a single
  reading means nothing, and utilization is the delta between two of them. So the caller
  keeps the previous `sample/0` and passes both to `utilization/2`. The counter is
  enabled once at boot (`enable/0`); until a second sample exists, utilization is `nil`
  rather than a made-up zero.
  """
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor

  @doc "Turn on the scheduler counter. Called once at boot; safe to call again."
  def enable, do: :erlang.system_flag(:scheduler_wall_time, true)

  @doc """
  A raw scheduler-time reading. Meaningless alone; feed two to `utilization/2`.

  If the counter is off (a node that skipped `enable/0`, an iex session, a test), the
  first call switches it on and returns `nil` - there is nothing to read yet. The next
  call gets a real reading. So CPU comes up on its own rather than staying dark forever
  because of boot order.
  """
  @spec sample() :: list() | nil
  def sample do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined ->
        enable()
        nil

      list ->
        Enum.sort(list)
    end
  end

  @doc """
  Scheduler utilization (0-100) between two samples, or `nil` when it can't be known
  yet (no previous sample, or the counter is off). Never fabricates a zero.
  """
  @spec utilization(list() | nil, list() | nil) :: float() | nil
  def utilization(prev, curr) when is_list(prev) and is_list(curr) and prev != [] do
    {active, total} =
      Enum.zip(prev, curr)
      |> Enum.reduce({0, 0}, fn {{_i, a0, t0}, {_i2, a1, t1}}, {a, t} ->
        {a + (a1 - a0), t + (t1 - t0)}
      end)

    if total > 0, do: Float.round(active * 100 / total, 1), else: nil
  end

  def utilization(_prev, _curr), do: nil

  @doc "Memory the node currently holds, in MB."
  @spec memory_mb() :: float()
  def memory_mb, do: Float.round(:erlang.memory(:total) / 1_048_576, 1)

  @doc "How many conversations are alive right now (one supervised process each)."
  @spec sessions() :: non_neg_integer()
  def sessions, do: length(SessionSupervisor.list())

  @doc "Total processes on the node - the BEAM's own, plus one per live conversation."
  @spec processes() :: non_neg_integer()
  def processes, do: :erlang.system_info(:process_count)

  @doc "How long the node has been up, in seconds."
  @spec uptime_seconds() :: non_neg_integer()
  def uptime_seconds do
    {ms, _} = :erlang.statistics(:wall_clock)
    div(ms, 1000)
  end

  @doc "A snapshot of the whole node, for the dashboard's footprint panel."
  @spec footprint() :: map()
  def footprint do
    %{
      memory_mb: memory_mb(),
      sessions: sessions(),
      processes: processes(),
      uptime_seconds: uptime_seconds()
    }
  end

  @doc """
  What each agent's live conversations are holding: `%{agent_name => %{sessions:,
  memory_kb:}}`. One pass over the live sessions, so it stays cheap with many agents.

  This is the memory of the **session processes** (their retained context), not of a
  turn in flight, which runs in a short-lived task. That is the number that matters for
  "what does it cost to keep this agent's conversations open".
  """
  @spec by_agent() :: %{optional(String.t()) => %{sessions: pos_integer(), memory_kb: non_neg_integer()}}
  def by_agent do
    Enum.reduce(SessionSupervisor.list(), %{}, fn key, acc ->
      with agent when is_binary(agent) <- agent_of(key),
           kb when is_integer(kb) <- memory_kb_of(key) do
        Map.update(acc, agent, %{sessions: 1, memory_kb: kb}, fn m ->
          %{sessions: m.sessions + 1, memory_kb: m.memory_kb + kb}
        end)
      else
        _ -> acc
      end
    end)
  end

  # A session that dies while we're walking the list must not take the panel with it.
  defp agent_of(key) do
    case Session.status(key) do
      %{agent: agent} -> agent
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp memory_kb_of(key) do
    with [{pid, _}] <- Registry.lookup(Pepe.Agent.Registry, key),
         {:memory, bytes} <- Process.info(pid, :memory) do
      div(bytes, 1024)
    else
      _ -> nil
    end
  end
end
