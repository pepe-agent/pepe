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

  @optional_callbacks concurrent?: 0

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
