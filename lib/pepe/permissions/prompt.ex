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

  @options [:once, :session, :always, :deny]
  @all_options [:once, :this_run, :session, :always, :deny]

  @doc """
  The decisions offered to the user, in display order. `:this_run` only appears while the
  current run is tainted (pass the `:tainted` flag from the call's own `ctx`) - offering it
  outside a tainted run would just be a confusing synonym for `:session`, since untainted
  pre-approval already works normally. See `Pepe.Permissions`' moduledoc for why `:this_run`
  exists at all.
  """
  @spec options(boolean()) :: [Permissions.decision()]
  def options(tainted? \\ false)
  def options(true), do: @all_options
  def options(false), do: @options

  @doc "The button/menu label for a decision (translated, current locale)."
  @spec label(Permissions.decision()) :: String.t()
  def label(:once), do: gettext("✅ Allow once")
  def label(:this_run), do: gettext("🔁 Allow for the rest of this task")
  def label(:session), do: gettext("💬 Allow for this session")
  def label(:always), do: gettext("♾️ Always allow")
  def label(:deny), do: gettext("🚫 Don't allow")

  @doc "The confirmation shown after a decision is made (translated)."
  @spec outcome(Permissions.decision()) :: String.t()
  def outcome(:once), do: gettext("✅ Allowed once.")
  def outcome(:this_run), do: gettext("🔁 Allowed for the rest of this task.")
  def outcome(:session), do: gettext("💬 Allowed for this session.")
  def outcome(:always), do: gettext("♾️ Always allowed.")
  def outcome(:deny), do: gettext("🚫 Not allowed.")

  @doc "A short, stable, locale-independent token for a decision (for payloads)."
  @spec token(Permissions.decision()) :: String.t()
  def token(decision) when decision in @all_options, do: Atom.to_string(decision)

  @doc """
  Parse a token back into a decision. Unknown tokens map to `:deny` - the safe
  default, and it avoids `String.to_atom/1` on outside input.
  """
  @spec from_token(String.t()) :: Permissions.decision()
  def from_token("once"), do: :once
  def from_token("this_run"), do: :this_run
  def from_token("session"), do: :session
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
      "" -> gettext("🔐 Allow me to run the %{tool} tool?", tool: "`#{tool}`")
      desc -> gettext("🔐 Allow me to run the %{tool} tool — %{desc}?", tool: "`#{tool}`", desc: desc)
    end
  end

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
    gettext("Any of these covers calls like this one, which flag no risk. Anything riskier will ask again.")
  end

  def scope_note(risks) do
    gettext("Any of these covers %{tool} calls that %{risks}. Anything else it does will ask again.",
      tool: gettext("this tool's"),
      risks: Enum.map_join(risks, ", ", &Pepe.Permissions.Risk.label/1)
    )
  end
end
