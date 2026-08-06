defmodule Pepe.Invocation do
  @moduledoc """
  How an operator actually invokes this program right now, for instructional text meant
  for THEM to type back (an error page, a "run this to fix it" hint). `mix pepe ...`
  only means anything to a developer running from source with deps installed; a real
  install runs the compiled `pepe` binary directly, and an instruction telling that
  operator to type `mix` is telling them to run a command that doesn't exist for them.
  """

  @doc """
  The command prefix an instructional string should show: `"pepe"` for the compiled
  (Burrito) binary, `"mix pepe"` when running from source.
  """
  @spec command() :: String.t()
  def command do
    if Burrito.Util.running_standalone?(), do: "pepe", else: "mix pepe"
  end
end
