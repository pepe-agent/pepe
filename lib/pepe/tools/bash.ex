defmodule Pepe.Tools.Bash do
  @moduledoc "Run a shell command and return combined stdout/stderr."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "bash"

  @impl true
  def spec do
    function(
      "bash",
      "Run a shell command on the host and return its combined output (stdout+stderr). Reach for this to inspect or change the real system, and to settle anything exactly instead of guessing it: the current date/time, files and their contents, processes and ports, git state, arithmetic, checksums. Chain steps with `&&` and pipes to get more done in one call.",
      %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The shell command to run."},
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default 60000)."
          }
        },
        "required" => ["command"]
      }
    )
  end

  @impl true
  def run(%{"command" => command} = args, ctx) do
    cwd = ctx[:cwd] || File.cwd!()
    timeout = args["timeout_ms"] || 60_000

    case Pepe.Sandbox.guard(command) do
      {:block, why} -> {:error, "refused: #{why}"}
      :ok -> run_guarded(command, cwd, timeout)
    end
  end

  def run(_, _), do: {:error, "missing 'command'"}

  defp run_guarded(command, cwd, timeout) do
    task =
      Task.async(fn ->
        Pepe.Sandbox.cmd("sh", ["-c", command], cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} ->
        {:ok, "exit_status=#{status}\n#{truncate(output)}"}

      nil ->
        {:error, "command timed out after #{timeout}ms"}
    end
  end

  defp truncate(text, max \\ 30_000) do
    if byte_size(text) > max do
      binary_part(text, 0, max) <> "\n...(truncated)"
    else
      text
    end
  end
end
