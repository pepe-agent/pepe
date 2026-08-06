defmodule Pepe.Gateways.Channel do
  @moduledoc """
  A plugin's persistent-connection chat channel - the shape Telegram itself already is
  (a supervised, long-lived process: a long-poll loop, a websocket, whatever the platform
  needs), as opposed to `Pepe.Webhooks.Provider`, which only covers inbound HTTP.

  This is additive, like a tool or a webhook provider (see `Pepe.Tools`/`Pepe.Webhooks`),
  never a slot (see `Pepe.Slots`): several persistent channels run at once, the same way
  several Telegram bots already can.

  `child_specs/0` returns the specs this plugin wants running right now - typically `[]`
  when it has no credentials configured yet (see `Pepe.Gateways.Telegram.bot_active?/1` for
  the precedent this mirrors), one spec per active connection otherwise. It is called fresh
  on every (re)load, so it always reflects the current config.
  """

  @callback name() :: String.t()
  @callback child_specs() :: [Supervisor.child_spec() | {module(), term()} | module()]
end
