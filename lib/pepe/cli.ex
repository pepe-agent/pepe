defmodule Pepe.CLI do
  @moduledoc """
  Entry point for the standalone `pepe` escript executable.

  Build it with `mix escript.build`, then call `pepe <command>` instead of
  `mix pepe <command>`. The actual command dispatch lives in
  `Mix.Tasks.Pepe.dispatch/1`, so the escript and the Mix task stay in sync.
  """

  def main(argv) do
    # Flag read by Mix.Tasks.Pepe's output helpers so usage/help text says
    # `pepe ...` instead of `mix pepe ...` - this entry point has no `mix`.
    Process.put(:pepe_cli_standalone, true)
    Mix.Tasks.Pepe.apply_locale()
    Mix.Tasks.Pepe.dispatch(argv)
  end
end
