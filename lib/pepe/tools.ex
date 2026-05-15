defmodule Pepe.Tools do
  @moduledoc """
  Registry of tools - the built-in `@builtin` set plus drop-in plugins.

  Turns an agent's tool allowlist into OpenAI tool specs / execute calls. Plugins
  are `.exs` files under `<PEPE_HOME>/plugins/`, each defining a module that
  implements the `Pepe.Tools.Tool` behaviour. They're compiled at runtime and
  hot-reloaded on change (by mtime) - drop a file and it works on the next call, no
  restart. Built-ins win on a name collision.
  """

  alias Pepe.Tools.Bash
  alias Pepe.Tools.ConfigGet
  alias Pepe.Tools.ConfigSet
  alias Pepe.Tools.Delegate
  alias Pepe.Tools.Docs
  alias Pepe.Tools.Doctor
  alias Pepe.Tools.EditFile
  alias Pepe.Tools.EnableTool
  alias Pepe.Tools.EndSession
  alias Pepe.Tools.FetchUrl
  alias Pepe.Tools.Goal
  alias Pepe.Tools.Invoice
  alias Pepe.Tools.ListDir
  alias Pepe.Tools.ManageAgent
  alias Pepe.Tools.ManageChannel
  alias Pepe.Tools.ManageMcp
  alias Pepe.Tools.ManagePepe
  alias Pepe.Tools.ManagePlugin
  alias Pepe.Tools.ManageToken
  alias Pepe.Tools.MoveFile
  alias Pepe.Tools.Plan
  alias Pepe.Tools.ReadFile
  alias Pepe.Tools.RenameAgent
  alias Pepe.Tools.Review
  alias Pepe.Tools.RunScript
  alias Pepe.Tools.ScanSkill
  alias Pepe.Tools.ScheduleTask
  alias Pepe.Tools.SendFile
  alias Pepe.Tools.SendToAgent
  alias Pepe.Tools.SetRoute
  alias Pepe.Tools.Skill
  alias Pepe.Tools.Watch
  alias Pepe.Tools.WebSearch
  alias Pepe.Tools.WriteFile

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
    SendFile,
    Invoice,
    EndSession,
    Goal,
    Plan,
    Skill,
    Docs,
    Doctor,
    SendToAgent,
    Delegate,
    ScheduleTask,
    ManageChannel,
    ManageAgent,
    ManageMcp,
    ManagePepe,
    ManagePlugin,
    ManageToken,
    ScanSkill,
    RenameAgent,
    ConfigGet,
    ConfigSet,
    EnableTool,
    SetRoute,
    Review,
    Watch
  ]

  @doc "All tool modules - built-ins plus loaded plugins."
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
  def plugins_dir, do: Pepe.Plugins.dir()

  # A tool plugin is any plugin module exporting the tool shape (name/spec/run).
  defp plugins, do: Pepe.Plugins.implementing([{:name, 0}, {:spec, 0}, {:run, 2}])

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

    case builtin ++ Pepe.MCP.specs_for(names) do
      [] -> nil
      specs -> specs
    end
  end

  def specs(_), do: nil

  @doc """
  May this tool run alongside the others the model asked for in the same turn?

  False unless the tool says otherwise, which is the safe way round: the failure it
  prevents is silent (two edits to one file racing, one overwriting the other), while the
  cost of being wrong the other way is only that something took longer than it had to. A
  tool nobody has thought about yet, an MCP tool from a server we know nothing about, and
  a plugin written against the older behaviour all land here and run in series.
  """
  @spec concurrent?(String.t()) :: boolean()
  def concurrent?(name) do
    case by_name()[name] do
      nil -> false
      mod -> function_exported?(mod, :concurrent?, 0) and mod.concurrent?()
    end
  end

  @doc """
  Execute a tool call. `tool_call` is the OpenAI tool_call map. Returns the
  string result (always - errors are turned into a readable string for the model).
  """
  def execute(%{"function" => %{"name" => name}} = call, ctx \\ %{}) do
    call |> run_only(ctx) |> finalize(name, ctx)
  end

  @doc """
  Run the tool body and nothing else. No redaction, no spilling.

  Split out from `execute/2` so the runtime can run concurrent tools in tasks while keeping
  everything that depends on the *calling* process here at home. Both redaction and
  spilling do: redaction's reversible map lives in the process dictionary, so a tool that
  redacted inside its own task would throw its map away, and the same email seen by two
  tools would come back as two different tokens.
  """
  @spec run_only(map(), map()) :: String.t()
  def run_only(%{"function" => %{"name" => name, "arguments" => raw_args}}, ctx \\ %{}) do
    if Pepe.MCP.mcp_tool?(name) do
      execute_mcp(name, raw_args)
    else
      execute_builtin(name, raw_args, ctx)
    end
  end

  @doc """
  Redact and spill a raw tool result. Must run in the process that owns the turn.
  """
  @spec finalize(String.t(), String.t(), map()) :: String.t()
  def finalize(result, name, ctx) do
    result
    |> redact(ctx)
    |> spill_large(name, ctx)
  end

  # A tool result can surface PII a human never typed (a DB query, a file read) -
  # redact it before it ever joins the conversation or gets spilled to disk, using
  # the same reversible-map hooks as the inbound message. Grows the calling
  # process's accumulator (Pepe.Hooks.start_map/1) so repeated PII across several
  # tool calls in one turn gets the same token, and so the final entries flow back
  # to whoever owns the turn (Pepe.Agent.Session) for the closing restore/2.
  defp redact(result, %{agent: %Pepe.Config.Agent{} = agent}) do
    {redacted, entries} = Pepe.Hooks.transform(:tool_result, result, agent, %{"map" => Pepe.Hooks.current_map()})
    Pepe.Hooks.add_entries(entries)
    redacted
  end

  defp redact(result, _ctx), do: result

  # Keep huge tool output out of the context window: past the threshold, save the
  # full text to a file in the agent's workspace and hand the model a preview + the
  # path (it can `read_file` slices on demand). Protects the window from a single
  # noisy command; `read_file` itself is exempt (reading a file back would loop).
  # Runs on the already-redacted text, so a spilled file never carries raw PII either.
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
          "Full output saved to #{path} - read slices of it with read_file if needed.]"
    end
  rescue
    _ -> result
  end

  defp spill_large(result, _name, _ctx), do: result

  defp spill_dir(%{agent: %{name: name}}) when is_binary(name),
    do: Path.join(Pepe.Agent.Workspace.dir(name), "tmp")

  defp spill_dir(_), do: nil

  defp execute_mcp(name, raw_args) do
    with {:ok, args} <- decode_args(raw_args),
         {:ok, out} <- Pepe.MCP.call(name, args) do
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
      catch
        # A tool that `exit`s or `throw`s (a plugin, mostly) must not escape as a linked task
        # crash. When it runs inside a concurrent batch it is a `Task.async_stream` child linked
        # to the turn, and a bare `exit` there kills the turn before the stream can turn it into
        # a result. Caught here, at the source, it is just another failed tool call.
        :exit, reason -> "Error: tool #{name} crashed: #{inspect(reason)}"
        :throw, value -> "Error: tool #{name} threw: #{inspect(value)}"
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
