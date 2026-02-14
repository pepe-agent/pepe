defmodule CortexWeb.LiveLocale do
  @moduledoc """
  A LiveView `on_mount` hook that applies the configured locale (from
  `~/.cortex/config.json`) to Gettext for every dashboard LiveView — so each one
  renders in the language chosen at setup without repeating `Config.put_locale/0` in
  every `mount/3`. Attached once via `live_session on_mount:` in the router.
  """

  def on_mount(:default, _params, _session, socket) do
    Cortex.Config.put_locale()
    {:cont, socket}
  end
end
