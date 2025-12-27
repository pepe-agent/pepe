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
  alias Cortex.Tools.EditFile
  alias Cortex.Tools.EnableTool
  alias Cortex.Tools.FetchUrl
  alias Cortex.Tools.ListDir
  alias Cortex.Tools.MoveFile
  alias Cortex.Tools.ReadFile
  alias Cortex.Tools.RenameAgent
  alias Cortex.Tools.RunScript
  alias Cortex.Tools.SendToAgent
  alias Cortex.Tools.SetRoute
  alias Cortex.Tools.Skill
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
    Skill,
    SendToAgent,
    RenameAgent,
    ConfigGet,
    ConfigSet,
    EnableTool,
    SetRoute
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
    specs =
      names
      |> Enum.map(&get/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.spec())

    case specs do
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
