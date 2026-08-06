defmodule Pepe.Slots.Guard do
  @moduledoc """
  Runs a slot call through its currently-configured occupant. On anything that isn't a
  clean `{:ok, _}` return - a crash, a timeout, a malformed shape - what happens next
  depends on the slot's own `degrade_mode/1` (`Pepe.Slots.degrade_mode/1`): `:fallback`
  (most slots) degrades to the slot's default, "failures never block replies", because a
  misbehaving occupant there only changes answer quality; `:error` returns the failure
  instead, for a slot (`sandbox`) whose whole point is running something somewhere other
  than the default, where silently falling back would mean silently giving up the
  isolation the occupant existed to provide.

  The builtin default is called directly (a rescue/catch, no `Task`) - it's core code we
  trust the shape of. A non-default (plugin) occupant is called in a supervised, unlinked
  `Task`: unlinked because the caller is the turn-owning process (a Session, a webhook
  handler), and a linked crash there would kill the turn itself, not just this one call.

  Deliberately no cooldown/circuit-breaker here (unlike `Pepe.LLM.Cooldown`, which exists
  to skip a real HTTP round trip): a slot fallback already costs about nothing once its
  timeout fires. Add one only if a real slow-occupant-on-a-hot-path case shows up.

  A backend module runs inside a bare `Task`, with an empty process dictionary - no
  `Pepe.Permissions` taint, no `Pepe.Hooks` redaction map. A slot backend must be pure with
  respect to turn/trust state; anything taint- or redaction-related stays in the caller.

  A `{:ok, payload}` is also checked against the slot's own `validate/1` (see
  `Pepe.Slots.validator_for/1`) - the tuple shape alone isn't proof the payload inside it
  is what the caller's actual code expects (a list of `Pepe.Memory.Hit`, say), and a
  malformed-but-tagged-`:ok` return would otherwise sail straight through to whatever the
  caller does next, crashing there instead of degrading here.

  The timeout on a non-default occupant's `Task` is enforced from *inside* that Task
  itself, not only by the caller's own `Task.yield`/`shutdown` - because the caller (a
  Session) can die mid-call, and an `async_nolink` Task is deliberately not tied to its
  caller's lifetime. Without a self-enforced deadline, a caller dying mid-call would orphan
  the occupant's Task for as long as the occupant keeps running (unbounded, for a hung
  plugin) - self-enforcing means the Task always winds itself down within `timeout`
  regardless of whether anyone ever comes back to collect the result.

  The caller's own `Task.yield`/`shutdown` on the *outer* Task (`guarded_apply/5`) waits
  `timeout + @grace_ms`, not bare `timeout` - found live, via a repeated leaked-process
  reproduction: with both windows equal, the outer wait and the outer Task's own internal
  enforcement of the *inner* Task (`self_enforced_call/4`) race, both timed from nearly the
  same instant. If the outer's `brutal_kill` won that race, it could kill the outer Task
  mid-way through its own `Task.shutdown` of the inner one - leaving the inner Task (the
  actual hung occupant call) with nobody left to ever kill it, orphaned for as long as it
  keeps running. The grace period gives the outer Task's own internal enforcement room to
  always finish first under normal scheduling, so the caller's `brutal_kill` fires only in
  the genuinely pathological case (the runtime so starved even that doesn't complete in
  time) rather than racing it on every single call.
  """

  require Logger

  @grace_ms 1_000

  @doc """
  Call `fun` with `args` on `slot`'s current occupant for `agent` (or the
  installation-wide occupant, if `agent` is nil or declares no override for this slot -
  see `Pepe.Slots.occupant/2`). Returns whatever the occupant (or, on fallback, the
  default) returns - `{:ok, term()} | {:error, term()}`.
  """
  @spec call(String.t(), atom(), [term()], Pepe.Config.Agent.t() | nil) :: {:ok, term()} | {:error, term()}
  def call(slot, fun, args, agent \\ nil) do
    default = Pepe.Slots.default_for(slot)
    mod = Pepe.Slots.occupant(slot, agent)
    validator = Pepe.Slots.validator_for(slot)

    if mod == default do
      safe_apply(mod, fun, args, validator)
    else
      case guarded_apply(mod, fun, args, Pepe.Slots.timeout_for(slot), validator) do
        {:ok, _} = ok ->
          Pepe.Slots.Health.clear(slot)
          ok

        {:error, reason} ->
          Pepe.Slots.Health.record_failure(slot, mod, reason)
          on_occupant_failure(Pepe.Slots.degrade_mode(slot), slot, mod, reason, default, fun, args, validator)
      end
    end
  end

  # :fallback (memory/web_search's default): a misbehaving occupant only changes answer
  # quality, so silently running the builtin instead is correct - see the moduledoc.
  defp on_occupant_failure(:fallback, slot, mod, reason, default, fun, args, validator) do
    Logger.warning("[slots] #{inspect(slot)} occupant #{inspect(mod)} failed (#{inspect(reason)}); degrading to the default for this call")

    safe_apply(default, fun, args, validator)
  end

  # :error (sandbox): the occupant's whole job was to run this call somewhere other than
  # the local host - silently falling back to the builtin here would mean running the
  # agent's command directly on the host the moment the isolation backend fails, which is
  # the exact boundary this mode exists to hold, not a bounded quality degradation.
  defp on_occupant_failure(:error, slot, mod, reason, _default, _fun, _args, _validator) do
    Logger.error("[slots] #{inspect(slot)} occupant #{inspect(mod)} failed (#{inspect(reason)}); refusing rather than falling back")
    {:error, reason}
  end

  # The default/builtin: trusted shape, no Task overhead - just don't let it crash the
  # caller. An optional callback the occupant doesn't implement (index/1, say) is a clean
  # :not_supported rather than an UndefinedFunctionError dressed up as a crash.
  #
  # Code.ensure_loaded?/1 first: function_exported?/3 (unlike a plain call through apply/3,
  # which triggers the code server's normal on-demand loading) does NOT load an unloaded
  # module first - it would otherwise report a real, compiled function as unsupported the
  # first time this module is ever touched in a given node.
  defp safe_apply(mod, fun, args, validator) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args) |> checked(validator)
    else
      {:error, :not_supported}
    end
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:crashed, {kind, reason}}}
  end

  defp checked({:ok, payload} = ok, validator), do: if(valid?(validator, payload), do: ok, else: {:error, {:bad_payload, payload}})
  defp checked({:error, _} = err, _validator), do: err
  defp checked(other, _validator), do: {:error, {:bad_return, other}}

  defp guarded_apply(mod, fun, args, timeout, validator) do
    task = Task.Supervisor.async_nolink(Pepe.Slots.TaskSupervisor, fn -> self_enforced_call(mod, fun, args, timeout) end)

    case Task.yield(task, timeout + @grace_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> checked(result, validator)
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  # Runs `apply/3` in its own nested Task and enforces `timeout` from inside this process,
  # independent of whether the outer caller ever comes back to yield/shutdown the Task
  # above (see the moduledoc). This Task always exits within `timeout`, on its own.
  defp self_enforced_call(mod, fun, args, timeout) do
    inner = Task.Supervisor.async_nolink(Pepe.Slots.TaskSupervisor, fn -> apply(mod, fun, args) end)

    case Task.yield(inner, timeout) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp valid?(nil, _payload), do: true
  defp valid?(validator, payload), do: validator.(payload)
end
