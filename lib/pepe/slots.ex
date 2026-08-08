defmodule Pepe.Slots do
  @moduledoc """
  Exclusive extension points: unlike a tool or a webhook provider (where many plugins
  coexist additively - `Pepe.Plugins.implementing/1` feeding `Pepe.Tools`/`Pepe.Webhooks`),
  a slot has exactly one occupant at a time. "Memory search" is a slot: the operator
  either uses the builtin, or names one installed plugin to take over - never both, and
  never a silent pile-up of competing implementations answering the same question.

  The builtin occupant is not special-cased; it is simply the default when nothing is
  configured. Swapping a slot's occupant is reconfiguration (`mix pepe slot set NAME
  PLUGIN`, or `"slots": {"NAME": "PLUGIN"}` in `config.json`), never a code change.

  Resolution is agent override -> project's own `default_slots` -> the installation-wide
  `slots` config -> the builtin, the same shape `Pepe.Hooks` already uses for `hooks`/
  `default_hooks`. An agent's own `slots` map (`%{"memory" => "plugin_name"}`) wins over
  everything else - one agent in a project can be pinned to a different occupant than
  every other agent and project, without a global change nobody else asked for.

  A slot occupant is discovered the same way every other plugin surface is - a loaded
  module exporting the right functions - disambiguated from other slots' occupants (whose
  fun sets could collide) by an explicit `slot/0` callback, the same way `name/0`
  disambiguates tools and webhook providers from each other.

  Every actual call to a non-default occupant goes through `Pepe.Slots.Guard`, which by
  default degrades to the builtin on a crash, a timeout, or a malformed return - a slot
  occupant misbehaving changes answer quality, it never breaks a turn. That fallback is
  correct only because `memory`/`web_search` are read-only and idempotent - falling back
  to the builtin just means a worse answer, never a side effect the plugin occupant was
  specifically there to avoid. A slot whose whole point is changing WHERE/HOW something
  runs (`sandbox`) sets `degrade: :error` instead: falling back to the builtin there would
  mean silently running the agent's command on the local host the moment an isolation
  backend crashes or times out - exactly the boundary the slot exists to enforce, and (for
  a non-idempotent command) a real risk of running it twice if the plugin's own side
  effect already happened before it hung. See `Pepe.Slots.Guard`.
  """

  use Gettext, backend: Pepe.Gettext

  require Logger

  @doc """
  The known slots: name => %{label, desc, default, funs, degrade, timeout, validate}.
  `timeout`/`validate` are absent on "harness", the one slot not dispatched through
  `Pepe.Slots.Guard` - see its own comment below.

  `label`/`desc` exist purely so a human-facing surface (the dashboard's agent editor,
  `mix pepe slot list`) can name a slot in words instead of printing the raw key.
  """
  @spec definitions() :: %{String.t() => map()}
  def definitions do
    %{
      "memory" => %{
        label: gettext("Memory search"),
        desc: gettext("Where the agent looks things up in what it remembers."),
        default: Pepe.Memory.Builtin,
        funs: [{:name, 0}, {:slot, 0}, {:search, 3}],
        timeout: 3_000,
        validate: &valid_hits?/1,
        degrade: :fallback
      },
      "web_search" => %{
        label: gettext("Web search"),
        desc: gettext("Which service answers the agent's searches on the web."),
        default: Pepe.Search.DuckDuckGo,
        funs: [{:name, 0}, {:slot, 0}, {:search, 2}],
        timeout: 20_000,
        validate: &valid_results?/1,
        degrade: :fallback
      },
      # Where/how a shell command actually runs, for the `bash`/`run_script` tools - local
      # execution (optionally through the configured Config.sandbox/0 wrapper script) is the
      # default; a plugin can occupy this slot to run commands somewhere else entirely (SSH to
      # a remote host, a different container runtime driven from Elixir instead of a wrapper
      # script), reusing the same exclusive-slot isolation every other slot already gets -
      # except the *degradation*, see `degrade: :error` and the moduledoc above.
      #
      # This timeout only ever applies to a non-default (plugin) occupant - the builtin
      # (Pepe.Sandbox) is called directly, with no Task/timeout wrapper at all (see
      # Pepe.Slots.Guard.call/4's own-occupant fast path), so the calling tool's own timeout
      # (bash's `timeout_ms`, default 60s but caller-settable) remains the sole enforcement
      # for the common, no-plugin-installed case. Generous on purpose for the plugin case: a
      # remote-exec backend genuinely can take longer than a local command.
      "sandbox" => %{
        label: gettext("Command execution"),
        desc: gettext("Where a command the agent runs actually executes."),
        default: Pepe.Sandbox,
        funs: [{:name, 0}, {:slot, 0}, {:run, 3}],
        timeout: 300_000,
        validate: &valid_cmd_result?/1,
        degrade: :error
      },
      # How a long conversation gets condensed to fit the model's context window - a
      # different summarization strategy, a non-LLM heuristic, whatever a plugin wants
      # instead of Pepe.Agent.Compaction's own LLM-summarize-the-middle approach. A crash
      # or timeout here only means a worse (or no) condensation for this call, never a
      # broken turn, so this degrades like memory/web_search rather than sandbox.
      "compaction" => %{
        label: gettext("Conversation condensing"),
        desc: gettext("How a long conversation is shortened once it outgrows the model's memory."),
        default: Pepe.Agent.Compaction,
        funs: [{:name, 0}, {:slot, 0}, {:compact, 4}],
        timeout: 60_000,
        validate: &valid_messages?/1,
        degrade: :fallback
      },
      # The whole reasoning loop, not one call - see Pepe.Agent.Harness's moduledoc. No
      # `timeout`/`validate` here: unlike every other slot, Pepe.Agent.Runtime never
      # dispatches this one through Pepe.Slots.Guard at all (a harness occupant needs the
      # turn-owning process's own Permissions/taint state, which Guard's Task isolation
      # deliberately withholds from every other slot) - see
      # Pepe.Agent.Runtime.run_via_harness/3. `degrade: :error`, not :fallback: unlike a
      # worse search result, a harness that crashes mid-turn may already have taken
      # real, non-idempotent action (sent a reply, run a tool) through its own means -
      # silently re-running the whole turn from scratch on the builtin loop risks doing
      # that work twice, the same reasoning "sandbox" uses.
      "harness" => %{
        label: gettext("Reasoning loop"),
        desc: gettext("The whole think-and-act loop that drives one turn."),
        default: Pepe.Agent.Runtime,
        funs: [{:name, 0}, {:slot, 0}, {:run, 3}],
        degrade: :error
      }
    }
  end

  defp valid_hits?(hits), do: is_list(hits) and Enum.all?(hits, &match?(%Pepe.Memory.Hit{}, &1))
  defp valid_results?(results), do: is_list(results) and Enum.all?(results, &match?(%Pepe.Search.Result{}, &1))
  defp valid_cmd_result?({output, status}), do: is_binary(output) and is_integer(status)
  defp valid_cmd_result?(_), do: false
  defp valid_messages?(messages), do: is_list(messages) and Enum.all?(messages, &is_map/1)

  @doc "The known slot names."
  @spec names() :: [String.t()]
  def names, do: definitions() |> Map.keys() |> Enum.sort()

  @doc "Is `slot` one of the known slots?"
  @spec known?(String.t()) :: boolean()
  def known?(slot), do: Map.has_key?(definitions(), slot)

  @doc "A human, translated name for `slot` - falls back to the raw key if none is declared."
  @spec label_for(String.t()) :: String.t()
  def label_for(slot), do: Map.get(fetch!(slot), :label) || slot

  @doc "One line on what `slot` decides, for a human-facing surface. \"\" if none is declared."
  @spec desc_for(String.t()) :: String.t()
  def desc_for(slot), do: Map.get(fetch!(slot), :desc) || ""

  @doc "The default (builtin) module for `slot`."
  @spec default_for(String.t()) :: module()
  def default_for(slot), do: fetch!(slot).default

  @doc "The call timeout (ms) configured for `slot`."
  @spec timeout_for(String.t()) :: pos_integer()
  def timeout_for(slot), do: fetch!(slot).timeout

  @doc "The payload validator for `slot`'s `{:ok, payload}` shape, or nil if it doesn't declare one."
  @spec validator_for(String.t()) :: (term() -> boolean()) | nil
  def validator_for(slot), do: Map.get(fetch!(slot), :validate)

  @doc """
  How `Pepe.Slots.Guard` should react when a non-default occupant fails (crashes, times
  out, or returns something malformed): `:fallback` (the default - degrade to the
  builtin's own answer) or `:error` (return the failure instead of ever running the
  builtin) - see this module's moduledoc for why some slots need `:error`.
  """
  @spec degrade_mode(String.t()) :: :fallback | :error
  def degrade_mode(slot), do: Map.get(fetch!(slot), :degrade, :fallback)

  @doc "Is `slot` currently answered by a non-default (plugin) occupant, for `agent` (or globally if nil)?"
  @spec plugin_answering?(String.t(), Pepe.Config.Agent.t() | nil) :: boolean()
  def plugin_answering?(slot, agent \\ nil), do: occupant(slot, agent) != default_for(slot)

  @doc """
  The module that currently occupies `slot` for `agent` (or globally, if `agent` is nil or
  declares no override): the configured plugin if one is set, present, and actually claims
  this slot via `slot/0`; the default otherwise. Never raises, never crashes boot - a
  missing/misconfigured occupant just falls back, logged once per call.
  """
  @spec occupant(String.t(), Pepe.Config.Agent.t() | nil) :: module()
  def occupant(slot, agent \\ nil) do
    case configured_name(slot, agent) do
      name when name in [nil, "default"] ->
        default_for(slot)

      name ->
        case Enum.find(candidates(slot), &(&1.name == name)) do
          nil ->
            Logger.warning(
              "[slots] configured occupant #{inspect(name)} for slot #{inspect(slot)} is not installed or does not claim this slot; falling back to the default"
            )

            default_for(slot)

          %{module: mod} ->
            mod
        end
    end
  end

  # Agent override wins over the project's own default, which wins over the
  # installation-wide setting - same precedence Pepe.Hooks already uses for hooks.
  #
  # Map.get/3, not dot access: some callers (the tool-context shape in tests, and any
  # caller that only has an agent-shaped map rather than a real %Pepe.Config.Agent{})
  # pass something with `name` but no `slots` key at all - this must degrade to "no
  # override", not raise, same as it would for a real agent that just has an empty map.
  defp configured_name(slot, agent) do
    (agent && Map.get(Map.get(agent, :slots) || %{}, slot)) || project_default(slot, agent) ||
      Pepe.Config.slot_occupant(slot)
  end

  defp project_default(_slot, nil), do: nil

  defp project_default(slot, agent) do
    case Pepe.Project.of(agent.name) do
      nil -> nil
      co -> get_in(Pepe.Config.get_project(co) || %{}, ["default_slots", slot])
    end
  end

  @doc """
  Every installed plugin module currently eligible to occupy `slot`, plus the default's own
  entry - a plugin claims a slot by exporting the slot's fun set *and* `slot/0` returning
  this exact slot name (never inferred, never `String.to_atom/1`'d from outside input).

  A candidate's `slot/0`/`name/0` are read through `Pepe.Plugins.safe_call/3`: this runs in
  the calling process, before `Pepe.Slots.Guard`'s isolation exists for a plugin to run
  inside - a candidate whose metadata itself raises is simply not a candidate (logged,
  skipped), not a crash for every caller of every slot.
  """
  @spec candidates(String.t()) :: [%{name: String.t(), module: module(), default?: boolean()}]
  def candidates(slot) do
    %{default: default, funs: funs} = fetch!(slot)

    plugin_entries =
      funs
      |> Pepe.Plugins.implementing()
      |> Enum.flat_map(&candidate_entry(&1, slot))
      |> Enum.sort_by(& &1.name)

    [%{name: default.name(), module: default, default?: true} | plugin_entries]
  end

  defp candidate_entry(mod, slot) do
    with {:ok, ^slot} <- Pepe.Plugins.safe_call(mod, :slot, []),
         {:ok, name} when is_binary(name) <- Pepe.Plugins.safe_call(mod, :name, []) do
      [%{name: name, module: mod, default?: false}]
    else
      _ -> []
    end
  end

  @doc "Every known slot, its current occupant's name, its default's name, and any recent failure - for the dashboard/`mix pepe slot list`/Doctor."
  @spec status() :: [
          %{slot: String.t(), occupant: String.t(), default: String.t(), degraded?: boolean(), last_failure: map() | nil}
        ]
  def status do
    for slot <- names() do
      mod = occupant(slot)
      default = default_for(slot)
      configured = Pepe.Config.slot_occupant(slot)

      %{
        slot: slot,
        occupant: display_name(mod),
        default: default.name(),
        degraded?: configured not in [nil, "default", default.name()] and mod == default,
        last_failure: current_failure(slot, mod)
      }
    end
  end

  # A failure recorded against a PREVIOUS occupant of this slot (reconfigured since, or
  # simply reverted to the default) must not be reported as if the current one had it -
  # Pepe.Slots.Health keys purely by slot name, so this is where "still relevant" gets
  # decided, once, for every consumer (Doctor, `slot list`, the dashboard) instead of each
  # one re-deriving it.
  defp current_failure(slot, mod) do
    case Pepe.Slots.Health.last_failure(slot) do
      %{module: ^mod} = failure -> failure
      _ -> nil
    end
  end

  # The default is trusted, first-party code - called directly. A non-default occupant's
  # own name/0 goes through the same guard as candidates/1, for the same reason: Doctor and
  # `slot list` exist specifically to diagnose a broken plugin, and must not themselves
  # crash on the plugin they're diagnosing.
  defp display_name(mod) do
    case Pepe.Plugins.safe_call(mod, :name, []) do
      {:ok, name} when is_binary(name) -> name
      _ -> inspect(mod)
    end
  end

  defp fetch!(slot) do
    case Map.fetch(definitions(), slot) do
      {:ok, def} -> def
      :error -> raise ArgumentError, "unknown slot #{inspect(slot)} (known: #{inspect(names())})"
    end
  end
end
