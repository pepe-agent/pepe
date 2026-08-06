defmodule Pepe.Hooks do
  @moduledoc """
  The message-flow hook pipeline - the single place surfaces run redaction (and
  other transforms) through. A hook is opt-in: an agent with no `hooks` (and no
  project `default_hooks`) runs raw, exactly as before.

  `transform/4` runs an agent's hooks for a stage, threading the text and collecting
  the reversible map (pseudonym -> real). `restore/2` puts the real values back on the
  way out. Both are applied by `Pepe.Agent.Session`, so every surface (WhatsApp,
  Telegram, API, console) gets it uniformly - like token metering.

  The four built-in providers below are additive alongside plugin-supplied ones - see
  `Pepe.Hooks.Hook`'s moduledoc for what a plugin hook actually unlocks (real content
  mutation, not just observation).

  A third stage, `:tool_result`, runs on every tool's raw output before it ever
  joins the conversation or gets spilled to disk (see `Pepe.Tools.execute/2`) - a
  database query or file read can surface PII a human never typed, so it needs the
  same treatment as the inbound message. Its reversible-map entries accumulate in
  this process's dictionary (`start_map/1`/`current_map/0`/`add_entries/1`/
  `take_map/0`, the same ownership shape `Pepe.Trace` uses) rather than being
  threaded through every function's return value, since tool calls happen deep
  inside `Pepe.Agent.Runtime`'s loop - including nested ones from `send_to_agent`,
  which share the caller's process and so the same accumulator, with no extra
  wiring needed.
  """

  require Logger

  alias Pepe.Project
  alias Pepe.Config

  @map_key :pepe_hooks_map

  @providers %{
    "pii_redact" => Pepe.Hooks.PiiRedact,
    "llm_redact" => Pepe.Hooks.LlmRedact,
    "http_redact" => Pepe.Hooks.HttpRedact,
    "presidio" => Pepe.Hooks.Presidio
  }

  @doc "The hook module for a name (built-in or plugin), or nil."
  def provider(name), do: Map.get(registry(), name)

  @doc "Registered hook names (built-in plus installed plugins)."
  def names, do: registry() |> Map.keys() |> Enum.sort()

  @doc "Every hook provider, built-ins winning any name clash with a plugin - see Pepe.Hooks.Hook."
  def registry, do: Map.merge(plugin_providers(), @providers)

  defp plugin_providers do
    [{:name, 0}, {:stages, 0}, {:run, 4}]
    |> Pepe.Plugins.implementing()
    |> Enum.flat_map(fn mod ->
      case Pepe.Plugins.safe_call(mod, :name, []) do
        {:ok, name} when is_binary(name) -> [{name, mod}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  Run an agent's `stage` hooks over `text`. Returns `{text, entries}` where `entries`
  are new reversible-map items to remember for `restore/2`. Never raises - a hook
  failure falls back to the current text. Each hook that actually runs for this
  stage is recorded on the in-progress trace (a no-op if none - see
  `Pepe.Trace.event/1`), so redaction activity shows up in the trace UI without
  ever including the redacted values themselves.
  """
  @spec transform(atom(), String.t(), Pepe.Config.Agent.t() | nil, map()) ::
          {String.t(), [map()]}
  def transform(stage, text, agent, ctx \\ %{}) do
    # Carries the calling agent's handle to any hook that makes its own LLM call
    # (llm_redact), so that call meters against the right agent instead of vanishing
    # from spend entirely. Never overrides a caller-supplied "agent" already in ctx.
    ctx = Map.put_new(ctx, "agent", agent && agent.name)

    Enum.reduce(hooks_for(agent), {text, []}, fn {name, mod, settings}, {txt, entries} ->
      if stage in mod.stages() do
        apply_hook(stage, name, mod, settings, ctx, txt, entries)
      else
        {txt, entries}
      end
    end)
  end

  defp apply_hook(stage, name, mod, settings, ctx, txt, entries) do
    {new_txt, new_entries} =
      case safe_run(mod, stage, txt, settings, ctx) do
        {:ok, t} -> {t, []}
        {:ok, t, e} -> {t, e}
      end

    Pepe.Trace.event({:hook, stage, name, new_txt != txt, length(new_entries)})
    {new_txt, entries ++ new_entries}
  end

  @doc "Restore real values into `text` from the reversible map (longest token first)."
  @spec restore(String.t(), [map()]) :: String.t()
  def restore(text, []), do: text

  def restore(text, entries) do
    entries
    |> Enum.sort_by(&(-String.length(&1["fake"] || "")))
    |> Enum.reduce(text, fn e, acc ->
      String.replace(acc, e["fake"] || "", to_string(e["real"]))
    end)
  end

  @doc """
  Start this process's `:tool_result` reversible-map accumulator, seeded with
  `initial_entries` (typically the turn's already-known map: session history plus
  this turn's inbound entries). Call once, before `Pepe.Agent.Runtime.run/3` - tool
  calls made during the run (including nested ones, e.g. via `send_to_agent`, which
  share this process) fold their own discoveries in via `add_entries/1`. Read the
  result back with `take_map/0` once the run returns.
  """
  @spec start_map([map()]) :: :ok
  def start_map(initial_entries \\ []) when is_list(initial_entries) do
    Process.put(@map_key, initial_entries)
    :ok
  end

  @doc "The accumulator's current entries (`[]` if `start_map/1` was never called)."
  @spec current_map() :: [map()]
  def current_map, do: Process.get(@map_key) || []

  @doc "Append newly discovered entries to the accumulator. A no-op if none started."
  @spec add_entries([map()]) :: :ok
  def add_entries([]), do: :ok
  def add_entries(entries) when is_list(entries), do: Process.put(@map_key, current_map() ++ entries)

  @doc "Read the accumulator and clear it - call once, after the owning run completes."
  @spec take_map() :: [map()]
  def take_map do
    map = current_map()
    Process.delete(@map_key)
    map
  end

  @doc "Does this agent run any hooks at all? (fast path: skip the pipeline if not.)"
  def any?(agent), do: hooks_for(agent) != []

  @doc """
  Should a turn stream `:assistant_delta` events live? False whenever the agent has any
  hook configured, since a live delta is the model's raw, un-hooked text - showing it
  defeats an `:outbound` redaction/mutation hook before it ever runs (`transform/4` only
  sees the complete reply, once the run returns). A caller that gets `false` here should
  buffer instead: request a non-streaming run and render only the final, already-hooked
  text once it comes back, rather than the deltas as they arrive.
  """
  @spec stream?(Pepe.Config.Agent.t() | nil) :: boolean()
  def stream?(agent), do: not any?(agent)

  @doc "The `{name, module, settings}` list of hooks an agent runs - its own + project defaults."
  def hooks_for(nil), do: []

  def hooks_for(agent) do
    settings = Config.hooks_settings()

    agent
    |> hook_names()
    |> Enum.map(fn name -> {name, provider(name), Map.get(settings, name, %{})} end)
    |> Enum.reject(fn {_name, mod, _settings} -> is_nil(mod) end)
  end

  # An agent's own hooks plus any inherited from its project's `default_hooks`.
  defp hook_names(agent) do
    project_defaults =
      case Project.of(agent.name) do
        nil -> []
        co -> (Config.get_project(co) || %{})["default_hooks"] || []
      end

    (project_defaults ++ (agent.hooks || [])) |> Enum.uniq()
  end

  defp safe_run(mod, stage, text, settings, ctx) do
    mod.run(stage, text, settings, ctx)
  rescue
    e ->
      Logger.warning("[hooks] #{inspect(mod)} failed at #{stage}: #{Exception.message(e)}")
      {:ok, text}
  end
end
