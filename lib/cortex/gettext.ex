defmodule Cortex.Gettext do
  @moduledoc """
  Gettext backend for Cortex's **fixed system messages** — the strings Cortex
  itself emits (chat command replies, error notices, …), as opposed to the agent's
  own replies, which always follow the language the user is speaking.

  Source strings (msgids) are written in English; translations live under
  `priv/gettext/<locale>/LC_MESSAGES/default.po`. The active locale comes from the
  config `locale` (set during `mix cortex setup`); supported: `en`, `pt_BR`,
  `pt_PT`, `es`.

      use Gettext, backend: Cortex.Gettext
      gettext("New conversation started.")
  """
  use Gettext.Backend, otp_app: :cortex
end
