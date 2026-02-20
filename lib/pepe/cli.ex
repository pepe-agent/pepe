defmodule Pepe.CLI do
  @moduledoc """
  Entry point for the standalone `pepe` escript executable.

  Build it with `mix escript.build`, then call `pepe <command>` instead of
  `mix pepe <command>`. The actual command dispatch lives in
  `Mix.Tasks.Pepe.dispatch/1`, so the escript and the Mix task stay in sync.
  """

  def main(argv) do
    Mix.Tasks.Pepe.dispatch(argv)
  end
end
