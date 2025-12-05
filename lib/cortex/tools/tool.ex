defmodule Cortex.Tools.Tool do
  @moduledoc """
  Behaviour for agent tools.

  A tool exposes:
    * `name/0`        — the function name the model calls
    * `spec/0`        — the OpenAI function/tool JSON spec
    * `run/2`         — execute with decoded `args` and a `ctx` map, returning a
                        string result (fed back to the model as a tool message)
  """

  @type ctx :: %{optional(atom()) => any()}

  @callback name() :: String.t()
  @callback spec() :: map()
  @callback run(args :: map(), ctx :: ctx()) :: {:ok, String.t()} | {:error, String.t()}

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
