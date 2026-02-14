defmodule Cortex.Tools do
  @moduledoc """
  Registry of tools — the built-in `@builtin` set plus drop-in plugins.

  Turns an agent's tool allowlist into OpenAI tool specs / execute calls. Plugins
  are `.exs` files under `<CORTEX_HOME>/plugins/`, each defining a module that
  implements the `Cortex.Tools.Tool` behaviour. They're compiled at runtime and
  hot-reloaded on change (by mtime) — drop a file and it works on the next call, no
  restart. Built-ins win on a name collision.
  """

  require Logger

  alias Cortex.Tools.Bash
  alias Cortex.Tools.ConfigGet
  alias Cortex.Tools.ConfigSet
  alias Cortex.Tools.Docs
  alias Cortex.Tools.Doctor
  alias Cortex.Tools.EditFile
  alias Cortex.Tools.EnableTool
  alias Cortex.Tools.FetchUrl
  alias Cortex.Tools.Invoice
  alias Cortex.Tools.ListDir
  alias Cortex.Tools.ManageAgent
  alias Cortex.Tools.ManageChannel
  alias Cortex.Tools.ManageMcp
  alias Cortex.Tools.MoveFile
  alias Cortex.Tools.ReadFile
  alias Cortex.Tools.RenameAgent
  alias Cortex.Tools.RunScript
  alias Cortex.Tools.ScanSkill
  alias Cortex.Tools.ScheduleTask
  alias Cortex.Tools.SendToAgent
  alias Cortex.Tools.SetRoute
  alias Cortex.Tools.Skill
  alias Cortex.Tools.Watch
  alias Cortex.Tools.WebSearch
  alias Cortex.Tools.WriteFile

  @builtin [
    Bash,
    RunScript,
    ReadFile,
    WriteFile,
    EditFile,
    MoveFile,
    ListDir,
    FetchUrl,
    WebSearch,
    Invoice,
    Skill,
    Docs,
    Doctor,
    SendToAgent,
    ScheduleTask,
    ManageChannel,
    ManageAgent,
    ManageMcp,
    ScanSkill,
    RenameAgent,
    ConfigGet,
    ConfigSet,
    EnableTool,
    SetRoute,
    Watch
  ]

  @doc "All tool modules — built-ins plus loaded plugins."
  def all, do: @builtin ++ plugins()

  @doc "Map of name => module. Built-ins take precedence over plugins on a clash."
  def by_name do
    Map.new(plugins() ++ @builtin, fn mod -> {mod.name(), mod} end)
  end

  @doc "List the names of all available tools."
  def names, do: Enum.map(all(), & &1.name())

  @doc "Look up a tool module by name."
  def get(name), do: Map.get(by_name(), name)

  ###
  ### plugins (drop-in .exs tools, hot-reloaded by mtime)
  ###

  @doc "Directory scanned for plugin tools."
  def plugins_dir, do: Path.join(Cortex.Config.home(), "plugins")

  defp plugins do
    case File.ls(plugins_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()
        |> Enum.flat_map(&load_plugin/1)

      _ ->
        []
    end
  end

  # Load a plugin file, recompiling only when it changed since last time.
  defp load_plugin(file) do
    path = Path.join(plugins_dir(), file)
    key = {__MODULE__, :plugin, path}

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :persistent_term.get(key, nil) do
          {^mtime, mods} ->
            mods

          _ ->
            mods = compile_plugin(path)
            :persistent_term.put(key, {mtime, mods})
            mods
        end

      _ ->
        []
    end
  end

  defp compile_plugin(path) do
    path
    |> Code.compile_file()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&tool_module?/1)
  rescue
    error ->
      Logger.warning("[plugins] failed to load #{path}: #{Exception.message(error)}")
      []
  end

  defp tool_module?(mod) do
    Code.ensure_loaded?(mod) and
      function_exported?(mod, :name, 0) and
      function_exported?(mod, :spec, 0) and
      function_exported?(mod, :run, 2)
  end

  @doc """
  Build the list of OpenAI tool specs for a list of tool names. Unknown names
  are skipped. An empty list yields nil (so callers omit the `tools` field).
  """
  def specs(names) when is_list(names) do
    builtin =
      names
      |> Enum.map(&get/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.spec())

    case builtin ++ Cortex.MCP.specs_for(names) do
      [] -> nil
      specs -> specs
    end
  end

  def specs(_), do: nil

  @doc """
  Execute a tool call. `tool_call` is the OpenAI tool_call map. Returns the
  string result (always — errors are turned into a readable string for the model).
  """
  def execute(%{"function" => %{"name" => name, "arguments" => raw_args}}, ctx \\ %{}) do
    result =
      if Cortex.MCP.mcp_tool?(name) do
        execute_mcp(name, raw_args)
      else
        execute_builtin(name, raw_args, ctx)
      end

    spill_large(result, name, ctx)
  end

  # Keep huge tool output out of the context window: past the threshold, save the
  # full text to a file in the agent's workspace and hand the model a preview + the
  # path (it can `read_file` slices on demand). Protects the window from a single
  # noisy command; `read_file` itself is exempt (reading a file back would loop).
  @spill_threshold 16_000
  @spill_preview 2_000

  defp spill_large(result, name, ctx)
       when byte_size(result) > @spill_threshold and name != "read_file" do
    case spill_dir(ctx) do
      nil ->
        result

      dir ->
        File.mkdir_p!(dir)
        path = Path.join(dir, "#{name}-#{System.unique_integer([:positive])}.txt")
        File.write!(path, result)

        String.slice(result, 0, @spill_preview) <>
          "\n\n[... output truncated: #{byte_size(result)} bytes total. " <>
          "Full output saved to #{path} — read slices of it with read_file if needed.]"
    end
  rescue
    _ -> result
  end

  defp spill_large(result, _name, _ctx), do: result

  defp spill_dir(%{agent: %{name: name}}) when is_binary(name),
    do: Path.join(Cortex.Agent.Workspace.dir(name), "tmp")

  defp spill_dir(_), do: nil

  defp execute_mcp(name, raw_args) do
    with {:ok, args} <- decode_args(raw_args),
         {:ok, out} <- Cortex.MCP.call(name, args) do
      to_string(out)
    else
      {:error, reason} -> "Error: #{name} failed: #{inspect(reason)}"
    end
  end

  defp execute_builtin(name, raw_args, ctx) do
    with mod when not is_nil(mod) <- get(name),
         {:ok, args} <- decode_args(raw_args) do
      try do
        case mod.run(args, ctx) do
          {:ok, result} -> to_string(result)
          {:error, reason} -> "Error: #{reason}"
        end
      rescue
        e -> "Error: tool #{name} crashed: #{Exception.message(e)}"
      end
    else
      nil -> "Error: unknown tool #{name}"
      {:error, reason} -> "Error: invalid arguments for #{name}: #{reason}"
    end
  end

  defp decode_args(raw) when is_map(raw), do: {:ok, raw}
  defp decode_args(""), do: {:ok, %{}}
  defp decode_args(nil), do: {:ok, %{}}

  defp decode_args(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "expected JSON object"}
      {:error, _} -> {:error, "malformed JSON"}
    end
  end
end
