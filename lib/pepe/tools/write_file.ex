defmodule Pepe.Tools.WriteFile do
  @moduledoc "Write (create or overwrite) a file on disk."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "write_file"

  @impl true
  def spec do
    function(
      "write_file",
      "Create a new file, or overwrite an existing one, with the full contents given. For a small change to a file that already exists, prefer edit_file so you don't have to reproduce the whole thing.",
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path (relative = your workspace; shared/... = shared space; or absolute)."
          },
          "content" => %{"type" => "string", "description" => "The full file contents to write."}
        },
        "required" => ["path", "content"]
      }
    )
  end

  @impl true
  def run(%{"path" => path, "content" => content}, ctx) when is_binary(path) do
    full = resolve(path, ctx)
    File.mkdir_p!(Path.dirname(full))

    case File.write(full, content) do
      :ok -> {:ok, "wrote #{byte_size(content)} bytes to #{full}"}
      {:error, reason} -> {:error, "cannot write #{full}: #{:file.format_error(reason)}"}
    end
  end

  def run(%{"path" => _, "content" => _}, _ctx), do: {:error, "'path' must be a string"}
  def run(_, _), do: {:error, "missing 'path' or 'content'"}

  defp resolve(path, ctx), do: Pepe.Agent.Workspace.resolve_in_ctx(path, ctx)
end
