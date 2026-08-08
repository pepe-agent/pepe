defmodule Pepe.Invocation do
  @moduledoc """
  How an operator actually invokes this program right now, for instructional text meant
  for THEM to type back (an error page, a "run this to fix it" hint). `mix pepe ...`
  only means anything to a developer running from source with deps installed; a real
  install runs the compiled `pepe` binary directly, and a plain OTP release (the
  Docker image, `PEPE_PLAIN_RELEASE=1`) is a THIRD case, distinct from both: it has no
  `mix`, and its own `bin/pepe <args>` doesn't dispatch a CLI at all (that only fires for
  the Burrito binary, see `Pepe.Application.release_cli?/0`), so telling that operator to
  type either `mix pepe ...` or plain `pepe ...` hands them a command that doesn't work.
  A plain release is only reachable while running via `bin/pepe rpc`/`remote`, which needs
  `Mix.Tasks.Pepe.dispatch_attached/1`, not the free-text shape the other two cases use.
  """

  @doc """
  A full, copy-pasteable command for the given CLI args, correct for whichever of the
  three contexts above is actually running right now.
  """
  @spec hint([String.t()]) :: String.t()
  def hint(args) when is_list(args) do
    cond do
      Burrito.Util.running_standalone?() -> Enum.join(["pepe" | Enum.map(args, &shell_word/1)], " ")
      plain_release?() -> "bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(#{inspect(args)})'"
      true -> Enum.join(["mix pepe" | Enum.map(args, &shell_word/1)], " ")
    end
  end

  @doc """
  Whether this is a plain OTP release (the Docker image) rather than the Burrito
  binary or a `mix pepe` dev run. `bin/pepe rpc`/`remote`, the only way in from
  this context, has no real interactive terminal attached to the expression it
  evaluates, so a caller building a hint that involves interactive input (a hidden
  password prompt, a `select`/`confirm`) should route around that here rather than
  suggest something that would just hang.

  `RELEASE_NAME` is set by the standard `mix release` boot scripts (`bin/RELNAME
  start`), which Burrito's Zig wrapper doesn't go through: it execs the extracted
  ERTS directly instead, so this is only ever true for a plain release. Same signal
  `Pepe.Application.release_cli?/0` relies on the absence of.
  """
  @spec plain_release?() :: boolean()
  def plain_release?, do: not Burrito.Util.running_standalone?() and System.get_env("RELEASE_NAME") != nil

  defp shell_word(word) do
    if String.contains?(word, " "), do: "'#{word}'", else: word
  end
end
