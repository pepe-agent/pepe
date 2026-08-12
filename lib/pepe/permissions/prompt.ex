defmodule Pepe.Permissions.Prompt do
  @moduledoc """
  The shared vocabulary for the "may I run this tool?" prompt, reused by every
  surface so the choices, wording and outcomes stay consistent across gateways.

  A gateway renders the prompt in its own native widget - Telegram an inline
  keyboard, the CLI an arrow-key menu - but draws the option list, button labels,
  decision tokens and confirmation text from here. The core
  (`Pepe.Permissions`) owns *what a decision means*; this module owns *how it's
  offered and acknowledged*. All strings are translated via Gettext.
  """

  use Gettext, backend: Pepe.Gettext

  alias Pepe.Permissions

  @options [:once, :this_run, :session, :session_any, :session_bypass, :always, :deny]

  @doc """
  The decisions offered to the user, in display order. `:this_run` and `:session_bypass`
  are both blanket "everything, no more checks" grants - see `Pepe.Permissions`' moduledoc
  for how they differ (bounded by the run vs. bounded by the session) - and both are
  offered unconditionally now, tainted or not: `:this_run` used to appear only while the
  run was tainted, but tying a button's very presence to an implementation detail nobody
  can see turned out to be more confusing than helpful, not less.

  `tainted?` is accepted for backward compatibility with existing callers and no longer
  changes which decisions are offered; a surface still wants the flag separately, to
  decide whether to render `taint_note/0` and to pick `label/2`'s "(recommended)" wording.

  `has_session?` (default `true`, so an existing caller passing only `tainted?` is
  unaffected) drops `:session`, `:session_any` and `:session_bypass` when there is no
  `ctx.session_key` to remember them against - a one-shot CLI call (`mix pepe run`,
  `oneshot/4`) has no session, and offering a button that silently does nothing is worse
  than not offering it: the person picks it believing it will stop the prompt from coming
  back, and it never does (that was a real bug - see `Pepe.Permissions.gate/3`'s moduledoc).
  """
  @spec options(boolean(), boolean()) :: [Permissions.decision()]
  def options(tainted? \\ false, has_session? \\ true)
  def options(_tainted?, has_session?), do: with_session(@options, has_session?)

  defp with_session(list, true), do: list
  defp with_session(list, false), do: Enum.reject(list, &(&1 in [:session, :session_any, :session_bypass]))

  @doc """
  The button/menu label for a decision (translated, current locale).

  `:this_run` is marked "(recommended)" when `tainted?` is true: while `:session`/`:always`
  are suspended by a tainted run (see `Pepe.Permissions`' moduledoc), it's the cheapest grant
  that still silences repeat prompts for the rest of that run - a person who taps the
  familiar "session"/"always" button here, out of habit, gets asked again on the very next
  risky call and never finds out why. `:session_bypass` carries a warning emoji in its label
  itself rather than a conditional marker: unlike every other decision here, it is not
  suspended by taint at all (see the moduledoc's "the one grant that skips the taint check"),
  so that needs to be visible on the button, not just explained once nearby.
  """
  @spec label(Permissions.decision(), boolean()) :: String.t()
  def label(decision, tainted? \\ false)
  def label(:this_run, true), do: gettext("Allow everything for this task (recommended)")
  def label(:this_run, false), do: gettext("Allow everything for this task")
  def label(:once, _tainted?), do: gettext("Allow once")
  def label(:session, _tainted?), do: gettext("Allow for this session")
  def label(:session_any, _tainted?), do: gettext("Allow with any parameters (this session)")
  def label(:session_bypass, _tainted?), do: gettext("⚠️ Allow everything for this session")
  def label(:always, _tainted?), do: gettext("Always allow")
  def label(:deny, _tainted?), do: gettext("Don't allow")

  @doc "The confirmation shown after a decision is made (translated)."
  @spec outcome(Permissions.decision()) :: String.t()
  def outcome(:once), do: gettext("Allowed once.")
  def outcome(:this_run), do: gettext("Allowed everything for this task.")
  def outcome(:session), do: gettext("Allowed for this session.")
  def outcome(:session_any), do: gettext("Allowed with any parameters, for this session.")
  def outcome(:session_bypass), do: gettext("⚠️ Allowed everything for this session.")
  def outcome(:always), do: gettext("Always allowed.")
  def outcome(:deny), do: gettext("Not allowed.")

  @doc "A short, stable, locale-independent token for a decision (for payloads)."
  @spec token(Permissions.decision()) :: String.t()
  def token(decision) when decision in @options, do: Atom.to_string(decision)

  @doc """
  Parse a token back into a decision. Unknown tokens map to `:deny` - the safe
  default, and it avoids `String.to_atom/1` on outside input.
  """
  @spec from_token(String.t()) :: Permissions.decision()
  def from_token("once"), do: :once
  def from_token("this_run"), do: :this_run
  def from_token("session"), do: :session
  def from_token("session_any"), do: :session_any
  def from_token("session_bypass"), do: :session_bypass
  def from_token("always"), do: :always
  def from_token(_other), do: :deny

  @doc """
  The question text for a tool, e.g. for a prompt header (translated). Includes a one-line summary
  of what the tool does when we have one, so an internal name like `manage_pepe` isn't opaque to
  whoever is being asked to approve it.
  """
  @spec question(String.t()) :: String.t()
  def question(tool) do
    case Pepe.Tools.summary(tool) do
      "" -> gettext("Allow me to run the %{tool} tool?", tool: "`#{tool}`")
      desc -> gettext("Allow me to run the %{tool} tool: %{desc}?", tool: "`#{tool}`", desc: desc)
    end
  end

  @doc """
  Why this prompt is showing up again even though "session"/"always" was already granted
  earlier in the same task. Shown only while the run is tainted - explaining it once, right
  where the person is about to pick an option, is cheaper than them wondering why a task
  that "already got approved" is asking a fifth time.
  """
  @spec taint_note() :: String.t()
  def taint_note do
    gettext(
      "This task read something from outside the conversation, so a standing \"session\"/\"always\" approval doesn't apply here. Pick \"Allow everything for this task\" to stop it asking again for the rest of this one."
    )
  end

  @doc """
  Why a `Pepe.Permissions.Policy` plugin is asking about this call specifically, or `nil`
  when it wasn't a policy that forced this prompt. Shown so a human can tell a
  policy-forced ask apart from the gate's own ordinary one - the two are remembered
  under different grants (see `Pepe.Permissions.gate/3`'s moduledoc), so knowing which
  question is being answered matters.
  """
  @spec policy_note(String.t() | nil) :: String.t() | nil
  def policy_note(nil), do: nil
  def policy_note(reason), do: reason

  @doc """
  What a "session" or "always" answer will actually cover, given the risks of the call being
  asked about.

  The point of saying it out loud: a permission is only meaningful if the person granting it
  knows its width. "Always allow bash" sounds like one thing while you are looking at `ls`
  and turns out to be another the day the agent reaches for `rm`. It no longer is, and this
  is the sentence that tells you so.
  """
  @spec scope_note([Pepe.Permissions.Risk.kind()]) :: String.t()
  def scope_note([]) do
    gettext("Any of these covers calls like this one, which flag no risk. Anything riskier will ask again.") <>
      " " <> any_params_note() <> " " <> bypass_note()
  end

  def scope_note(risks) do
    gettext("Any of these covers %{tool} calls that %{risks}. Anything else it does will ask again.",
      tool: gettext("this tool's"),
      risks: Enum.map_join(risks, ", ", &Pepe.Permissions.Risk.label/1)
    ) <> " " <> any_params_note() <> " " <> bypass_note()
  end

  defp any_params_note do
    gettext(
      "\"Allow with any parameters\" is different: it stops checking parameters for this tool entirely, for the rest of this session."
    )
  end

  defp bypass_note do
    gettext(
      "\"⚠️ Allow everything for this session\" is the broadest one: it stops asking about any tool at all, for the rest of the session, even during a task that reads something from outside the conversation. Use it only when you're comfortable not being asked again for a while."
    )
  end
end
