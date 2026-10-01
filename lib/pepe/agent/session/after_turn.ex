defmodule Pepe.Agent.Session.AfterTurn do
  @moduledoc """
  What a session was asked to do once the turn that is running right now ends: move to
  another agent (`switch_agent`, `hand_back`), clear its own context (`end_session`), and
  whether the message being answered goes along to the new agent. Those requests arrive
  mid-turn from a tool and cannot be applied then, because rebinding the session while the
  run task still reads its own snapshot of the history would corrupt what it reports back.

  Everything pending belongs to *that* turn, so it is dropped as one unit (`clear/1`)
  whenever the turn ends any other way than normally (a `/stop`, a `/new`, a crashed run).
  Only `asked` outlives a turn on purpose: it is the message that raised a plain-text
  "move you to the right agent?" question, kept until the user's answer arrives as the next
  turn (see `Pepe.Tools.HandBack`), and only a `/new` forgets it (`new/0`).
  """

  defstruct agent: nil, reset?: false, forward?: false, forward_text: nil, asked: nil

  @type t :: %__MODULE__{}

  # A message re-sent to another agent may be re-sent again by that agent, and so on. Two
  # hops covers specialist -> router -> specialist; beyond that two agents are handing one
  # message back and forth, so it stops being forwarded.
  @max_forward_hops 2

  @doc "Nothing pending, nothing asked."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Drop everything pending for the turn that is ending, keeping only what `asked` carries."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{asked: asked}), do: %__MODULE__{asked: asked}

  @doc "Move to `target` after the turn; `forward?` also re-sends the message being answered."
  @spec switch(t(), String.t(), boolean()) :: t()
  def switch(%__MODULE__{} = at, target, forward?), do: %{at | agent: target, forward?: forward?, forward_text: nil}

  @doc """
  Move to `target` and re-send what `ask/2` remembered instead of the current message (the
  "yes" that answered a plain-text question). With nothing remembered it only moves.
  """
  @spec switch_asked(t(), String.t()) :: t()
  def switch_asked(%__MODULE__{asked: text} = at, target) when is_binary(text),
    do: %{at | agent: target, forward?: true, forward_text: text, asked: nil}

  def switch_asked(%__MODULE__{} = at, target), do: switch(at, target, false)

  @doc "Clear the context after the turn."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = at), do: %{at | reset?: true}

  @doc "Remember the message that raised a plain-text question, for the answer that follows."
  @spec ask(t(), String.t()) :: t()
  def ask(%__MODULE__{} = at, text) when is_binary(text), do: %{at | asked: text}

  @doc """
  What the session does with the conversation now that the turn finished normally:

    * `{:switch, target, forward}` - continue as `target` with a fresh context. `forward` is
      `{text, opts}` when the message goes along (the turn's own caller then waits for the new
      agent's answer), `nil` when it does not.
    * `:reset` - same agent, fresh context.
    * `:carry` - nothing pending; the history carries over.

  A switch beats a reset (it already starts fresh). A target that no longer exists is not
  bound to: the conversation stays with the agent that answered, with a fresh context. A
  message is forwarded only when the conversation really moves to a different agent
  (`same?` compares two agent references) and under the hop bound.
  """
  @spec decide(t(), String.t(), map(), (String.t(), String.t() -> boolean())) ::
          {:switch, String.t(), {String.t(), keyword()} | nil} | :reset | :carry
  def decide(%__MODULE__{agent: target} = at, agent_name, running, same?) when is_binary(target) do
    if is_nil(Pepe.Config.get_agent(target)) do
      :reset
    else
      hops = running.opts[:forward_hops] || 0

      forward =
        if at.forward? and hops < @max_forward_hops and not same?.(target, agent_name),
          do: {at.forward_text || running.text, Keyword.put(running.opts, :forward_hops, hops + 1)}

      {:switch, target, forward}
    end
  end

  def decide(%__MODULE__{reset?: true}, _agent_name, _running, _same?), do: :reset
  def decide(%__MODULE__{}, _agent_name, _running, _same?), do: :carry
end
