defmodule Pepe.Tools.ReadFile do
  @moduledoc "Read a file from disk."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "read_file"

  @impl true
  def spec do
    function("read_file", "Read the contents of a text file.", %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "File path. Relative paths are in your persistent workspace; use shared/... for the shared space, or an absolute path."
        }
      },
      "required" => ["path"]
    })
  end

  # Reads a file and changes nothing, so it cannot race with the tool beside it.
  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"path" => path}, ctx) do
    full = resolve(path, ctx)

    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{full}: #{:file.format_error(reason)}"}
    end
  end

  def run(_, _), do: {:error, "missing 'path'"}

  defp resolve(path, ctx), do: Pepe.Agent.Workspace.resolve_in_ctx(path, ctx)
end
