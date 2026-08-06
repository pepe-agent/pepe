defmodule Pepe.Permissions.Policy do
  @moduledoc """
  Additive, plugin-provided veto power over `Pepe.Permissions.gate/3` - a security/policy
  plugin (an approval-decision layer) can refuse a tool call this gate would otherwise
  have allowed, on grounds only the operator's own plugin knows (a company policy, an
  external allowlist service, a rate limiter) - or, short of an outright refusal, force a
  human to look at a call that would otherwise have been silently pre-approved
  (`:ask`/`{:ask, reason}` - a policy doesn't have to be certain enough to block outright
  to still want a person in the loop). Every installed policy is consulted on every gate
  call, for every agent it applies to - not opt-in like `Pepe.Hooks`, because installing
  one is only ever *more* restrictive: there's no safety reason to let an agent opt out
  of a veto layer the operator chose to install. "Applies to" can still be narrowed by
  the *operator*, though, never the agent itself: `Pepe.Config.put_policy_scope/2`
  (`"policy_scope"` in `config.json`, by agent name and/or project) limits which agents a
  policy is even consulted for - unscoped (the default, and the original behavior before
  this existed) means every agent.

  **Fail-closed, unlike the rest of Pepe's plugin surfaces.** Every other plugin
  extension point in this codebase degrades to "as if the plugin weren't there" on a
  crash or timeout (`Pepe.Slots.Guard`, `Pepe.Agent.RunObservers`, `Pepe.Hooks`'s own
  mutation pipeline) - fail-open is correct there because the plugin's job is to add or
  transform, and a broken one should just get out of the way. A policy plugin's job is
  the opposite: to say no. A `check/3` that raises, times out, or returns anything other
  than an explicit `:allow` denies the call - "a security check I couldn't run" is not
  the same thing as "a security check that passed", and treating it as a pass is exactly
  the failure mode a fail-closed veto layer exists to guard against.

  Checked once per gate call, sequentially, before any of `Pepe.Permissions.gate/3`'s own
  pre-approval/taint logic - a policy veto overrides even an `:always`-approved grant.
  "Most restrictive wins": the first `{:deny, _}` short-circuits the rest.

  A policy can also gate a whole run before it starts, ahead of any tool call - the
  optional `check_run/3` callback. `check/3` is tool-call-scoped: a turn that never calls
  a tool (a plain chat reply) never reaches it at all, so a policy that needs to say
  "this agent should not process this message" (a banned sender, a rate limit on
  messages rather than tool calls) has nothing to hook into without this. Opt-in per
  policy (`@optional_callbacks check_run: 3`) since most policies only have something to
  say about a specific tool call, not a bare chat turn - a policy that doesn't implement
  it simply doesn't participate in this checkpoint. Same fail-closed contract as
  `check/3`. Unlike a tool-call `:ask` (which prompts a human interactively through
  `ctx[:authorize]`), there is no pre-run approval UI today - `:ask` from `check_run/3`
  is currently treated the same as `:deny` (the run is blocked, the reason surfaced)
  rather than left to fail open; a real interactive pre-run ask is a documented gap, not
  built here.
  """

  require Logger

  @timeout 3_000

  @callback name() :: String.t()
  @callback check(tool_name :: String.t(), args :: map(), ctx :: map()) ::
              :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
  @callback check_run(agent :: struct(), first_message :: String.t(), ctx :: map()) ::
              :allow | :ask | {:ask, String.t()} | :deny | {:deny, String.t()}
  @optional_callbacks check_run: 3

  @doc """
  Consult every installed policy plugin that's in scope for `ctx[:agent]` (see
  `Pepe.Config.policy_scope/1`). `:allow` only if every one of them allows; `{:ask, reason}`
  if none deny but at least one wants a human to look (a policy that isn't certain enough
  to outright block); `{:deny, reason}` (most restrictive) wins over both, from any single
  policy, immediately.
  """
  @spec veto(String.t(), term(), map()) :: :allow | {:ask, String.t()} | {:deny, String.t()}
  def veto(tool_name, args, ctx) do
    case policies(ctx) do
      [] ->
        :allow

      mods ->
        decoded = Pepe.Permissions.decode(args)
        Enum.reduce_while(mods, :allow, &check_tool_call(&1, tool_name, decoded, ctx, &2))
    end
  end

  defp check_tool_call(mod, tool_name, args, ctx, acc), do: check_one(mod, fn -> mod.check(tool_name, args, ctx) end, acc)

  @doc """
  The message-level counterpart to `veto/3`: consulted once per run, before it starts, by
  any installed (and in-scope) policy that opts in via the optional `check_run/3` callback -
  see this module's moduledoc. `:allow` if none apply or every one of them allows;
  `{:ask, reason}`/`{:deny, reason}` (folded the same way `veto/3` does) otherwise.
  """
  @spec veto_run(struct(), String.t(), map()) :: :allow | {:ask, String.t()} | {:deny, String.t()}
  def veto_run(agent, first_message, ctx) do
    ctx = Map.put(ctx, :agent, agent)

    case run_policies(ctx) do
      [] -> :allow
      mods -> Enum.reduce_while(mods, :allow, &check_run_call(&1, agent, first_message, ctx, &2))
    end
  end

  defp check_run_call(mod, agent, first_message, ctx, acc), do: check_one(mod, fn -> mod.check_run(agent, first_message, ctx) end, acc)

  # guarded_check/2 always returns one of exactly three normalized shapes - :allow,
  # {:ask, reason}, or {:deny, reason} (reason always a non-empty string) - so this stays a
  # plain 3-way fold instead of re-deriving what each of a policy's several raw return
  # shapes means every time it's consulted. `call_fn` is `fn -> mod.check(...) end` or
  # `fn -> mod.check_run(...) end` - the two checkpoints share every guard/normalize step,
  # only the actual callback invoked differs.
  defp check_one(mod, call_fn, acc) do
    case guarded_check(mod, call_fn) do
      :allow -> {:cont, acc}
      {:ask, reason} -> {:cont, escalate(acc, reason)}
      {:deny, _reason} = deny -> {:halt, deny}
    end
  end

  # Once one policy has escalated to :ask, a later policy's plain :allow must not
  # downgrade it back to :allow - only a :deny (handled above, via {:halt, ...}) outranks
  # an :ask. Keeps the FIRST policy's reason, not the last.
  defp escalate({:ask, _} = already, _reason), do: already
  defp escalate(:allow, reason), do: {:ask, reason}

  # A supervised, timed-out Task even though this is fail-closed on failure: a policy
  # plugin that hangs must still turn into a deny within a bounded time, not hang the
  # gate (and therefore the whole turn) indefinitely.
  defp guarded_check(mod, call_fn) do
    task = Task.Supervisor.async_nolink(Pepe.Permissions.Policy.TaskSupervisor, fn -> safe_call(call_fn) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, decision} ->
        normalize(decision, mod)

      {:exit, reason} ->
        Logger.error("[permissions] policy #{inspect(mod)} crashed (#{inspect(reason)}) - failing closed")
        {:deny, "a security policy plugin crashed - denying by default"}

      nil ->
        Logger.error("[permissions] policy #{inspect(mod)} timed out after #{@timeout}ms - failing closed")
        {:deny, "a security policy plugin timed out - denying by default"}
    end
  end

  # A policy's own raw return, collapsed to the three shapes check_one/5 understands - a
  # bare :ask/:deny (no reason offered) falls back to a generic, still-actionable message
  # naming the policy, and anything unrecognized fails closed exactly like a crash does.
  defp normalize(:allow, _mod), do: :allow
  defp normalize(:ask, mod), do: {:ask, default_ask_reason(mod)}
  defp normalize({:ask, reason}, mod), do: {:ask, valid_reason(reason) || default_ask_reason(mod)}
  defp normalize(:deny, mod), do: {:deny, default_deny_reason(mod)}
  defp normalize({:deny, reason}, mod), do: {:deny, valid_reason(reason) || default_deny_reason(mod)}

  defp normalize(other, mod) do
    Logger.error("[permissions] policy #{inspect(mod)} returned #{inspect(other)} - failing closed")
    {:deny, "a security policy plugin returned an unrecognized decision - denying by default"}
  end

  defp valid_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp valid_reason(_reason), do: nil

  defp default_ask_reason(mod), do: "security policy #{policy_name(mod)} wants a human to decide"
  defp default_deny_reason(mod), do: "denied by security policy #{policy_name(mod)}"

  defp safe_call(call_fn) do
    call_fn.()
  rescue
    e -> {:deny, "a security policy plugin raised (#{Exception.message(e)}) - denying by default"}
  catch
    kind, reason -> {:deny, "a security policy plugin #{kind} (#{inspect(reason)}) - denying by default"}
  end

  defp policy_name(mod) do
    case Pepe.Plugins.safe_call(mod, :name, []) do
      {:ok, name} when is_binary(name) -> name
      _ -> inspect(mod)
    end
  end

  # Duck-typing alone (name/0 + check/3) is how every other additive plugin surface in this
  # codebase discovers its modules, and that's fine there: a module that happens to also
  # export those two functions for an unrelated reason just doesn't do anything useful as,
  # say, a Hook - a narrow, contained no-op. Policy is different: it's fail-closed and
  # global, consulted on every gate call for every agent, so an accidental name/check
  # collision doesn't quietly no-op, it can deny every tool call in the installation until
  # someone notices. Requiring the explicit `@behaviour Pepe.Permissions.Policy` declaration
  # (checked via BEAM's own module attributes, not a callback) is the guard a narrower
  # surface doesn't need.
  @doc "Every installed policy's name and configured scope (nil = unscoped, applies to every agent) - for `mix pepe policy list`/the dashboard."
  @spec status() :: [%{name: String.t(), scope: map() | nil}]
  def status do
    [{:name, 0}, {:check, 3}]
    |> Pepe.Plugins.implementing()
    |> Enum.filter(&declares_policy?/1)
    |> Enum.map(fn mod ->
      name = policy_name(mod)
      %{name: name, scope: Pepe.Config.policy_scope(name)}
    end)
  end

  defp policies(ctx) do
    [{:name, 0}, {:check, 3}]
    |> Pepe.Plugins.implementing()
    |> Enum.filter(&(declares_policy?(&1) and in_scope?(&1, ctx)))
  end

  # Same discovery + scope filter as policies/1, plus: only a policy that also exports the
  # OPTIONAL check_run/3 (most don't - see the moduledoc) participates in veto_run/3.
  defp run_policies(ctx) do
    policies(ctx) |> Enum.filter(&function_exported?(&1, :check_run, 3))
  end

  defp declares_policy?(mod) do
    case Pepe.Plugins.safe_call(mod, :module_info, [:attributes]) do
      {:ok, attrs} -> __MODULE__ in (attrs |> Keyword.get_values(:behaviour) |> List.flatten())
      :error -> false
    end
  end

  # The operator's own scoping, not the agent's - see Pepe.Config.put_policy_scope/2 and
  # this module's moduledoc. No scope declared for this policy's name = unscoped = applies
  # to every agent, the original (and still the default) behavior.
  defp in_scope?(mod, ctx) do
    case Pepe.Config.policy_scope(policy_name(mod)) do
      nil -> true
      scope -> agent_in_scope?(scope, ctx[:agent])
    end
  end

  # No agent to check against (a call path that doesn't carry one) fails toward MORE
  # restrictive, not less - consistent with this whole module treating "couldn't determine
  # a security answer" as "the check still applies", never as a free pass.
  defp agent_in_scope?(_scope, nil), do: true

  defp agent_in_scope?(scope, agent) do
    agents = scope["agents"] || []
    projects = scope["projects"] || []

    cond do
      agents == [] and projects == [] -> true
      agent.name in agents -> true
      Pepe.Project.of(agent.name) in projects -> true
      true -> false
    end
  end
end
