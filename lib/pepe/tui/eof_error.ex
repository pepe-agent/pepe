defmodule Pepe.TUI.EOFError do
  @moduledoc """
  Raised by `Pepe.TUI.input/1` when stdin closes (EOF) while a prompt is
  waiting for an answer: a wizard whose terminal went away, or a pipe that
  ran out of lines. The CLI entry points rescue it and abort cleanly.
  """
  defexception message: "stdin closed (EOF) while waiting for interactive input"
end
