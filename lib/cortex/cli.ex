defmodule Cortex.CLI do
  @moduledoc """
  Entry point for the standalone `cortex` escript executable.

  Build it with `mix escript.build`, then call `cortex <command>` instead of
  `mix cortex <command>`. The actual command dispatch lives in
  `Mix.Tasks.Cortex.dispatch/1`, so the escript and the Mix task stay in sync.
  """

  def main(argv) do
    Mix.Tasks.Cortex.dispatch(argv)
  end
end
