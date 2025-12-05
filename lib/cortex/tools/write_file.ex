defmodule Cortex.Tools.WriteFile do
  @moduledoc "Write (create or overwrite) a file on disk."
  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "write_file"

  @impl true
  def spec do
    function("write_file", "Create or overwrite a file with the given contents.", %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "File path (relative = your workspace; shared/... = shared space; or absolute)."
        },
        "content" => %{"type" => "string", "description" => "The full file contents to write."}
      },
      "required" => ["path", "content"]
    })
  end

  @impl true
  def run(%{"path" => path, "content" => content}, ctx) do
    full = resolve(path, ctx)
    File.mkdir_p!(Path.dirname(full))

    case File.write(full, content) do
      :ok -> {:ok, "wrote #{byte_size(content)} bytes to #{full}"}
      {:error, reason} -> {:error, "cannot write #{full}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "missing 'path' or 'content'"}

  defp resolve(path, ctx), do: Cortex.Agent.Workspace.resolve_in_ctx(path, ctx)
end
