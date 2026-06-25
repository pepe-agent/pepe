defmodule Pepe.Tools.EditFile do
  @moduledoc "Replace an exact string within a file (like a targeted patch)."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "edit_file"

  @impl true
  def spec do
    function(
      "edit_file",
      "Replace an exact substring in a file with new text. `old_string` must match exactly, whitespace included, and appear exactly once - include enough surrounding context to make it unique. Prefer this over rewriting a whole file with write_file for a small, targeted change.",
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path (relative = your workspace; shared/... = shared space; or absolute)."
          },
          "old_string" => %{"type" => "string", "description" => "Exact text to find."},
          "new_string" => %{"type" => "string", "description" => "Replacement text."}
        },
        "required" => ["path", "old_string", "new_string"]
      }
    )
  end

  @impl true
  def run(%{"path" => path, "old_string" => old, "new_string" => new}, ctx) when is_binary(path) do
    full = resolve(path, ctx)

    with {:ok, content} <- File.read(full),
         occurrences <- count(content, old),
         :ok <- check_occurrences(occurrences) do
      updated = String.replace(content, old, new, global: false)
      File.write!(full, updated)
      {:ok, "edited #{full}"}
    else
      {:error, :enoent} -> {:error, "file not found: #{full}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def run(%{"path" => _, "old_string" => _, "new_string" => _}, _ctx), do: {:error, "'path' must be a string"}
  def run(_, _), do: {:error, "missing 'path', 'old_string' or 'new_string'"}

  defp count(content, sub) do
    content |> String.split(sub) |> length() |> Kernel.-(1)
  end

  defp check_occurrences(0), do: {:error, "old_string not found"}
  defp check_occurrences(1), do: :ok
  defp check_occurrences(n), do: {:error, "old_string found #{n} times; must be unique"}

  defp resolve(path, ctx), do: Pepe.Agent.Workspace.resolve_in_ctx(path, ctx)
end
