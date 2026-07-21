defmodule PepeWeb.LiveLocale do
  @moduledoc """
  A LiveView `on_mount` hook that applies the configured locale (from
  `~/.pepe/config.json`) to Gettext for every dashboard LiveView - so each one
  renders in the language chosen at setup without repeating `Config.put_locale/0` in
  every `mount/3`. Attached once via `live_session on_mount:` in the router.

  Also tags this LiveView's process as the source of any config write it goes on to
  make (`Pepe.Config.Journal`), the same one hook covering every dashboard page
  rather than every `handle_event` that calls `Config.put_*` tagging itself.
  """

  def on_mount(:default, _params, _session, socket) do
    Pepe.Config.put_locale()
    Pepe.Config.Journal.put_source("dashboard")
    {:cont, socket}
  end
end
