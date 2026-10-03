defmodule Pepe.Webhooks.Approval do
  @moduledoc """
  Asking for permission in plain text on a webhook channel (Slack, Teams, WhatsApp, ...).

  A webhook has no button to press, so until now a risky call that was not pre-approved was
  refused and parked for an operator to approve from the command line
  (`Pepe.Permissions.PendingApprovals`). Here the question is asked in the conversation itself
  and the answer is typed: the agent's run waits, the next message of that conversation is read
  by `Pepe.Permissions.TextDecision`, and if it is an answer from someone who may give it, it
  settles the question instead of reaching the agent.

  Off unless the connection names its approvers. `trainers` must be an explicit, non-empty list
  (`["*"]` meaning everyone, said on purpose); absent or `[]` leaves things as they were, with
  nobody to ask. The default for `trainers` is "everyone may teach", which is the right default
  for learning and the wrong one for approving a shell command, so it is not read as consent.

  Only the safer answers can be typed here: `allow`, `allow all` (this task), `allow session`
  and `deny`. The two widest grants, for the whole session and for good, stay with the surfaces
  that have a button for them. A reply that is not one of those is just a message.

  Like the rest of a webhook turn, the call is `untrusted`, so even a pre-approved tool asks
  here once the run has taken in something from outside, and the question shows the real
  command. An unanswered question is denied after `:webhook_approval_timeout_ms` (five minutes),
  with the reason the agent is told being "nobody answered", not "refused".
  """

  use Gettext, backend: Pepe.Gettext

  require Logger

  alias Pepe.Config
  alias Pepe.Permissions
  alias Pepe.Permissions.Prompt
  alias Pepe.Permissions.Risk
  alias Pepe.Permissions.TextDecision

  @registry Pepe.Webhooks.ApprovalRegistry
  @default_timeout_ms 300_000
  @allowed [:once, :this_run, :session_any, :deny]

  @doc """
  The `authorize` callback for a turn on this connection, or `nil` when the connection has not
  named approvers (so the turn behaves as it always did). `key` is the conversation's session
  key and `from` is where the question is sent.
  """
  @spec authorizer(map(), module(), String.t(), String.t()) :: (String.t(), term(), map() -> term()) | nil
  def authorizer(entry, mod, from, key) do
    if enabled?(entry) do
      fn name, args, ctx -> ask(entry, mod, from, key, name, args, ctx) end
    end
  end

  @doc "Whether this connection has named approvers at all."
  @spec enabled?(map()) :: boolean()
  def enabled?(entry), do: match?([_ | _], entry["trainers"])

  @doc """
  Offer a message to the question waiting on this conversation, if there is one. `:consumed`
  when it was an answer from someone who may give it (and so is not a message for the agent),
  `:pass` for anything else, including an answer from someone who may not.
  """
  @spec reply(map(), String.t(), String.t(), String.t() | nil) :: :consumed | :pass
  def reply(entry, key, actor, text) do
    with true <- enabled?(entry),
         decision when decision in @allowed <- TextDecision.parse(text || ""),
         true <- approver?(entry, actor),
         [{pid, _}] <- Registry.lookup(@registry, key) do
      send(pid, {:webhook_approval, decision})
      :consumed
    else
      _ -> :pass
    end
  end

  defp approver?(entry, actor), do: "*" in entry["trainers"] or actor in entry["trainers"]

  # Runs in the session's process, which is the one the reply is sent back to.
  defp ask(entry, mod, from, key, name, args, ctx) do
    case Registry.register(@registry, key, nil) do
      {:ok, _} ->
        try do
          Config.put_locale()
          deliver(mod, entry, from, prompt(name, args, ctx))
          await()
        after
          Registry.unregister(@registry, key)
        end

      {:error, {:already_registered, _}} ->
        {:deny, "another permission question is already waiting for an answer on this conversation"}
    end
  end

  defp await do
    timeout = timeout_ms()

    receive do
      {:webhook_approval, decision} -> decision
    after
      timeout -> {:deny, Permissions.timeout_reason(timeout)}
    end
  end

  defp deliver(mod, entry, from, text) do
    case mod.deliver(entry, from, text) do
      {:error, reason} -> Logger.warning("[webhooks] #{entry["slug"]}: could not ask for permission: #{inspect(reason)}")
      _ -> :ok
    end
  end

  defp prompt(name, args, ctx) do
    map = decode(args)

    [
      Prompt.question(name),
      risk_lines(name, map),
      Prompt.preview(map),
      if(ctx[:tainted] == true, do: Prompt.taint_note()),
      Prompt.policy_note(ctx[:policy_reason]),
      hint(is_binary(ctx[:session_key]))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp risk_lines(name, map) do
    case Risk.hints(name, map) do
      [] -> ""
      kinds -> Enum.map_join(kinds, "\n", &("- " <> Risk.label(&1)))
    end
  end

  defp hint(true), do: dgettext("webhooks", "Reply with: allow / allow all / allow session / deny")
  defp hint(false), do: dgettext("webhooks", "Reply with: allow / allow all / deny")

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(map) when is_map(map), do: map
  defp decode(_raw), do: %{}

  defp timeout_ms, do: Application.get_env(:pepe, :webhook_approval_timeout_ms, @default_timeout_ms)
end
