defmodule Pepe.Tools.MoveFile do
  @moduledoc "Move or rename a file or directory."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "move_file"

  @impl true
  def spec do
    function(
      "move_file",
      "Move or rename a file or directory. Both paths are relative to your workspace (use shared/... for the shared space, or absolute).",
      %{
        "type" => "object",
        "properties" => %{
          "from" => %{"type" => "string", "description" => "Existing file or directory path."},
          "to" => %{"type" => "string", "description" => "New path."}
        },
        "required" => ["from", "to"]
      }
    )
  end

  @impl true
  def run(%{"from" => from, "to" => to}, ctx) when is_binary(from) and is_binary(to) do
    src = resolve(from, ctx)
    dst = resolve(to, ctx)
    File.mkdir_p!(Path.dirname(dst))

    case File.rename(src, dst) do
      :ok -> {:ok, "moved #{src} -> #{dst}"}
      {:error, reason} -> {:error, "cannot move #{src}: #{:file.format_error(reason)}"}
    end
  end

  def run(%{"from" => _, "to" => _}, _ctx), do: {:error, "'from' and 'to' must be strings"}
  def run(_, _), do: {:error, "missing 'from' or 'to'"}

  defp resolve(path, ctx), do: Pepe.Agent.Workspace.resolve_in_ctx(path, ctx)
end
