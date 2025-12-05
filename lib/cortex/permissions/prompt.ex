defmodule Cortex.Permissions.Prompt do
  @moduledoc """
  The shared vocabulary for the "may I run this tool?" prompt, reused by every
  surface so the choices, wording and outcomes stay consistent across gateways.

  A gateway renders the prompt in its own native widget — Telegram an inline
  keyboard, the CLI an arrow-key menu — but draws the option list, button labels,
  decision tokens and confirmation text from here. The core
  (`Cortex.Permissions`) owns *what a decision means*; this module owns *how it's
  offered and acknowledged*. All strings are translated via Gettext.
  """

  use Gettext, backend: Cortex.Gettext

  alias Cortex.Permissions

  @options [:once, :session, :always, :deny]

  @doc "The decisions offered to the user, in display order."
  @spec options() :: [Permissions.decision()]
  def options, do: @options

  @doc "The button/menu label for a decision (translated, current locale)."
  @spec label(Permissions.decision()) :: String.t()
  def label(:once), do: gettext("✅ Allow once")
  def label(:session), do: gettext("💬 Allow for this session")
  def label(:always), do: gettext("♾️ Always allow")
  def label(:deny), do: gettext("🚫 Don't allow")

  @doc "The confirmation shown after a decision is made (translated)."
  @spec outcome(Permissions.decision()) :: String.t()
  def outcome(:once), do: gettext("✅ Allowed once.")
  def outcome(:session), do: gettext("💬 Allowed for this session.")
  def outcome(:always), do: gettext("♾️ Always allowed.")
  def outcome(:deny), do: gettext("🚫 Not allowed.")

  @doc "A short, stable, locale-independent token for a decision (for payloads)."
  @spec token(Permissions.decision()) :: String.t()
  def token(decision) when decision in @options, do: Atom.to_string(decision)

  @doc """
  Parse a token back into a decision. Unknown tokens map to `:deny` — the safe
  default, and it avoids `String.to_atom/1` on outside input.
  """
  @spec from_token(String.t()) :: Permissions.decision()
  def from_token("once"), do: :once
  def from_token("session"), do: :session
  def from_token("always"), do: :always
  def from_token(_other), do: :deny

  @doc "The question text for a tool, e.g. for a prompt header (translated)."
  @spec question(String.t()) :: String.t()
  def question(tool), do: gettext("🔐 Allow me to run the %{tool} tool?", tool: "`#{tool}`")
end
