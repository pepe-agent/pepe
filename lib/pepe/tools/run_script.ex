defmodule Pepe.Tools.RunScript do
  @moduledoc """
  Write a short program and run it - or re-run a script the agent saved earlier.

  This is how the agent tackles complex/multi-step tasks (read a PDF, crunch a
  spreadsheet, call an API): instead of doing them by hand, it writes a program and
  runs it. Provide inline `code` (with `language`) for a one-off, or a saved `file`
  (resolved in the agent's workspace, language inferred from the extension) to reuse
  a script across requests. Runs in the agent's workspace; returns stdout+stderr+exit
  code. Elixir (`.exs`) is always available here; others when installed.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Workspace

  @langs %{
    "python" => {"python3", ".py"},
    "node" => {"node", ".js"},
    "javascript" => {"node", ".js"},
    "ruby" => {"ruby", ".rb"},
    "bash" => {"bash", ".sh"},
    "sh" => {"sh", ".sh"},
    "elixir" => {"elixir", ".exs"}
  }

  @by_ext %{
    ".py" => {"python3", ".py"},
    ".js" => {"node", ".js"},
    ".rb" => {"ruby", ".rb"},
    ".sh" => {"bash", ".sh"},
    ".exs" => {"elixir", ".exs"},
    ".ex" => {"elixir", ".ex"}
  }

  @max_output 10_000

  @impl true
  def name, do: "run_script"

  @impl true
  def spec do
    function(
      "run_script",
      "Run a program for complex/multi-step work instead of doing it by hand. Give inline `code` (with `language`) for a one-off, OR a saved `file` to re-run (path in your workspace, language inferred from its extension). Optional `args` is a list of string arguments for the program. Returns stdout+stderr+exit code; iterate if it errors. Languages: python, node, ruby, bash, elixir (elixir is always available).",
      %{
        "type" => "object",
        "properties" => %{
          "language" => %{
            "type" => "string",
            "description" => "python | node | ruby | bash | elixir (optional when `file` has a known extension)"
          },
          "code" => %{
            "type" => "string",
            "description" => "Inline program source (use this OR file)."
          },
          "file" => %{
            "type" => "string",
            "description" => "Path to a saved script in your workspace to re-run (use this OR code)."
          },
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Arguments passed to the program."
          }
        },
        "required" => []
      }
    )
  end

  @impl true
  def run(args, ctx) do
    with {:ok, {bin, ext}} <- language(args),
         :ok <- available(bin),
         {:ok, path, cleanup} <- source(args, ext, ctx) do
      try do
        {output, status} =
          System.cmd(bin, [path | script_args(args)], stderr_to_stdout: true, cd: cwd(ctx))

        {:ok, "exit #{status}\n" <> truncate(output)}
      rescue
        error -> {:error, "failed to run: #{Exception.message(error)}"}
      after
        cleanup.()
      end
    end
  end

  defp language(%{"language" => lang}) when is_binary(lang) do
    case @langs[String.downcase(lang)] do
      nil -> {:error, "unsupported language #{lang} (use python, node, ruby, bash or elixir)"}
      pair -> {:ok, pair}
    end
  end

  defp language(%{"file" => file}) when is_binary(file) do
    case @by_ext[String.downcase(Path.extname(file))] do
      nil -> {:error, "can't infer language from #{file}; pass `language`"}
      pair -> {:ok, pair}
    end
  end

  defp language(_),
    do: {:error, "provide `language` (with `code`) or a `file` with a known extension"}

  defp available(bin) do
    if System.find_executable(bin),
      do: :ok,
      else: {:error, "#{bin} is not installed on this machine"}
  end

  defp source(%{"code" => code}, ext, _ctx) when is_binary(code) do
    path =
      Path.join(System.tmp_dir!(), "pepe_script_#{System.unique_integer([:positive])}#{ext}")

    File.write!(path, code)
    {:ok, path, fn -> File.rm(path) end}
  end

  defp source(%{"file" => file}, _ext, ctx) when is_binary(file) do
    path = Workspace.resolve_in_ctx(file, ctx)

    if File.regular?(path),
      do: {:ok, path, fn -> :ok end},
      else: {:error, "no such script: #{file}"}
  end

  defp source(_args, _ext, _ctx), do: {:error, "provide inline `code` or a saved `file`"}

  defp script_args(args), do: args |> Map.get("args", []) |> List.wrap() |> Enum.map(&to_string/1)

  # Run in the agent's workspace so files the script reads/writes live with the agent.
  defp cwd(ctx) do
    case ctx[:agent] do
      %{name: name} when is_binary(name) ->
        dir = Workspace.dir(name)
        File.mkdir_p!(dir)
        dir

      _ ->
        ctx[:cwd] || File.cwd!()
    end
  end

  defp truncate(output) when byte_size(output) > @max_output,
    do: binary_part(output, 0, @max_output) <> "\n...(truncated)"

  defp truncate(output), do: output
end
