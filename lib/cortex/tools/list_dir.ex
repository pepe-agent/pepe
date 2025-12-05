defmodule Cortex.Tools.ListDir do
  @moduledoc "List the entries in a directory."
  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "list_dir"

  @impl true
  def spec do
    function("list_dir", "List files and directories at a path.", %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory (relative = your workspace; shared/... = shared space; or absolute). Defaults to your workspace."
        }
      },
      "required" => []
    })
  end

  @impl true
  def run(args, ctx) do
    path = resolve(args["path"] || ".", ctx)

    case File.ls(path) do
      {:ok, entries} ->
        listing =
          entries
          |> Enum.sort()
          |> Enum.map(fn e ->
            kind = if File.dir?(Path.join(path, e)), do: "dir ", else: "file"
            "#{kind}  #{e}"
          end)
          |> Enum.join("\n")

        {:ok, "#{path}\n#{listing}"}

      {:error, reason} ->
        {:error, "cannot list #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp resolve(path, ctx), do: Cortex.Agent.Workspace.resolve_in_ctx(path, ctx)
end
