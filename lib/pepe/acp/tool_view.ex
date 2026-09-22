defmodule Pepe.ACP.ToolView do
  @moduledoc """
  How one of Pepe's tool calls is shown in an editor: the kind that picks its icon, a
  title that says *what* it is doing rather than what the tool is for, the files it
  touches, and what its result looks like.

  Pure functions over a tool name and its decoded arguments. `Pepe.ACP.Protocol` builds
  the wire messages out of these, so the presentation can be tested without a pipe.

  The mapping is deliberately name-based and coarse: a tool Pepe doesn't recognize (a
  plugin's, an MCP server's) is `"other"` with a bare title, which is the honest answer
  rather than a guess dressed up as a classification.
  """

  @kinds %{
    "read_file" => "read",
    "list_dir" => "read",
    "docs" => "read",
    "skill" => "read",
    "config_get" => "read",
    "session_search" => "read",
    "memory_search" => "read",
    "write_file" => "edit",
    "edit_file" => "edit",
    "move_file" => "move",
    "bash" => "execute",
    "run_script" => "execute",
    "run_code" => "execute",
    "fetch_url" => "fetch",
    "browser" => "fetch",
    "web_search" => "search",
    "update_plan" => "think"
  }

  # The argument that says most about a call, most specific first.
  @preview_keys ~w(path command url query name from goal)

  @title_limit 80
  @result_limit 20_000

  @doc "The ACP `ToolKind` for a tool; `\"other\"` for anything unrecognized."
  @spec kind(String.t()) :: String.t()
  def kind(name), do: Map.get(@kinds, name, "other")

  @doc """
  A title that reads like what is happening: `read_file: lib/pepe.ex`,
  `bash: mix test`. The bare tool name when its arguments say nothing worth showing.
  """
  @spec title(String.t(), map()) :: String.t()
  def title(name, args) when is_map(args) do
    case preview(name, args) do
      nil -> name
      text -> "#{name}: #{text}"
    end
  end

  def title(name, _args), do: name

  defp preview("move_file", %{"from" => from, "to" => to}) when is_binary(from) and is_binary(to),
    do: clip("#{from} -> #{to}")

  defp preview(_name, args) do
    Enum.find_value(@preview_keys, fn key ->
      case args[key] do
        value when is_binary(value) and value != "" -> clip(value)
        _ -> nil
      end
    end)
  end

  defp clip(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
    if String.length(line) > @title_limit, do: String.slice(line, 0, @title_limit - 3) <> "...", else: line
  end

  @doc """
  The files a call touches, as ACP `ToolCallLocation`s (absolute paths, so an editor can
  open them). `read_file`'s `offset` is the line it starts from.
  """
  @spec locations(String.t(), map(), String.t() | nil) :: [map()]
  def locations("move_file", %{"from" => from, "to" => to}, cwd) when is_binary(from) and is_binary(to),
    do: [%{"path" => absolute(from, cwd)}, %{"path" => absolute(to, cwd)}]

  def locations(name, %{"path" => path} = args, cwd)
      when name in ~w(read_file write_file edit_file list_dir) and is_binary(path) and path != "" do
    location = %{"path" => absolute(path, cwd)}

    case args["offset"] do
      line when is_integer(line) and line >= 1 -> [Map.put(location, "line", line)]
      _ -> [location]
    end
  end

  def locations(_name, _args, _cwd), do: []

  defp absolute(path, cwd), do: Pepe.ACP.Edits.resolve(path, cwd)

  @doc "A tool's output as ACP content: one text block, capped so a huge result can't flood the pipe."
  @spec result_content(term()) :: [map()]
  def result_content(output) do
    [%{"type" => "content", "content" => %{"type" => "text", "text" => cap(to_string(output))}}]
  end

  defp cap(text) do
    if String.length(text) > @result_limit do
      String.slice(text, 0, @result_limit) <> "\n... (#{String.length(text) - @result_limit} more characters not shown)"
    else
      text
    end
  end

  @doc """
  `true` when a result reads as a failure. Pepe's tools report failure with the
  `Error: ` prefix (`Pepe.Tools.error?/1`); a call that was denied is failed too, and
  the server decides that one.
  """
  @spec failed?(term()) :: boolean()
  def failed?(output) when is_binary(output), do: Pepe.Tools.error?(output)
  def failed?(_output), do: false
end
