defmodule Pepe.Tools.Tool do
  @moduledoc """
  Behaviour for agent tools.

  A tool exposes:
    * `name/0`        - the function name the model calls
    * `spec/0`        - the OpenAI function/tool JSON spec
    * `run/2`         - execute with decoded `args` and a `ctx` map, returning a
                        string result (fed back to the model as a tool message)
    * `concurrent?/0` - optional; may this tool run alongside the others the model
                        asked for in the same turn? Defaults to `false`.
    * `offered?/1`    - optional; is this tool on offer in *this* turn, given the turn's
                        `ctx`? Defaults to `true`.

  ## `offered?/1`: one question, asked once

  Some tools only make sense in some turns: `switch_agent` is pointless on a channel that
  locks agent switching, `hand_back` only works while the conversation is with an agent other
  than the channel's own. Whether a tool is on offer is decided here, in one place per tool,
  and the registry applies it twice: the model is never shown a tool that is off the table
  (it costs tokens every turn to describe a capability it cannot use), and a call to one anyway
  is refused at dispatch with the same answer. A tool therefore does not repeat the condition
  inside its own `run/2`.

  ## Why `concurrent?/0` defaults to false

  A model routinely asks for several tools at once, and the slow ones are almost always
  waiting on a network: reading three URLs one after another costs the sum of three round
  trips for no reason. So the runtime runs the concurrent ones together.

  It defaults to `false` because the failure it prevents is silent. Two `edit_file` calls
  on the same file, run at once, both read the original and one overwrites the other: the
  edit is lost, and nothing reports an error. Sequential edits compose. A new tool is
  therefore serial until somebody has actually thought about whether it can race with the
  ones beside it, rather than fast until somebody notices it corrupted something.

  Say `true` for a tool that only reads, or that reaches out to somewhere else. Leave it
  alone for anything that writes, executes, or otherwise changes the machine.
  """

  @type ctx :: %{optional(atom()) => any()}

  @callback name() :: String.t()
  @callback spec() :: map()
  @callback run(args :: map(), ctx :: ctx()) :: {:ok, String.t()} | {:error, String.t()}
  @callback concurrent?() :: boolean()
  @callback offered?(ctx :: ctx()) :: boolean()

  @optional_callbacks concurrent?: 0, offered?: 1

  @doc """
  Whether an agent has anyone to message or hand a conversation to (a non-empty
  `can_message`). With no calling agent in `ctx` there is nothing to judge, so the answer is
  yes and the tool's own check speaks. Shared by the routing tools' `offered?/1`, so an agent
  with nobody on its list is not shown tools that can only be refused.
  """
  @spec has_routes?(map() | nil) :: boolean()
  def has_routes?(nil), do: true
  def has_routes?(%{can_message: [_ | _]}), do: true
  def has_routes?(_agent), do: false

  @doc "Helper to build the standard OpenAI tool spec envelope."
  def function(name, description, parameters) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end
end
