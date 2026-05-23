defmodule Pepe.Agent.Utility do
  @moduledoc """
  The cheap model an agent uses for the small talk it has with itself.

  Some model calls are not the agent thinking, they are the agent tidying up: naming a
  conversation so the sidebar reads like something, and whatever chrome comes after it.
  Short input, short output, and nothing downstream reasons from the result. Running those
  on a frontier model is paying a cabinetmaker to hang a coat.

  Point an agent's `utility_model` at a connection you already have (a small, fast one) and
  those calls go there.

  ## Unset means "do it without a model", never "use the expensive one"

  With no `utility_model`, `model/1` returns `nil` and the caller does the job some cheaper
  way, or not at all. Naming a conversation, for instance, falls back to trimming the opening
  message down to a label: no model, no network, no cost.

  What it must never do is quietly fall back to the agent's own model. That would add
  spending nobody asked for to every install that upgraded, and Pepe bills those tokens to a
  project. A feature that costs money turns itself on when you say so, not when you upgrade.
  A name pointing at a connection that does not exist counts as unset for the same reason: a
  typo must not be the thing that starts spending. `pepe doctor` says so when it sees one.

  ## What does not belong here

  Anything whose output the agent then has to *reason from*. Compaction is the clear case: a
  summary written badly does not merely read badly, it silently misinforms every turn after
  it, and the agent cannot tell. It stays on the agent's own model on purpose. The rule is
  the shape of the failure, not the price: if being wrong here would only look clumsy, it is
  a utility call; if it would make the agent wrong, it is not.

  ## The reasoning-model trap

  A small model that *reasons* is not a cheap model. Give one a tight `max_tokens` and it
  spends the entire budget thinking and emits an empty string, so the call costs money and
  returns nothing. Callers here leave enough room for it to finish, and treat empty output as
  "no answer" rather than as an error worth reporting.
  """

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @doc """
  The connection an agent's utility calls run on, or `nil` when it has none configured (or
  names one that does not exist). `nil` means the caller skips the call entirely.
  """
  @spec model(Agent.t()) :: Model.t() | nil
  def model(%Agent{utility_model: name}) when is_binary(name) and name != "",
    do: Config.get_model(name)

  def model(%Agent{}), do: nil
end
