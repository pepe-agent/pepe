# Channels

Beyond Telegram (a poller) and the WebSocket / HTTP API, Pepe serves several messaging
channels through one inbound-webhook endpoint, `/webhooks/:company/:provider/:slug`.
Configure a connection on the dashboard **Channels** tab (or import one with
[migrate](migrating.md)); it shows the webhook URL to paste into the platform.

The built-in webhook channels:

| Channel | How it connects | Config it needs |
|---|---|---|
| **WhatsApp** | Meta Cloud API webhook | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Events API webhook | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Interactions endpoint (slash commands) | `public_key`, `application_id` |
| **Microsoft Teams** | Bot Framework webhook | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Chat API webhook | `access_token` (OAuth for the Chat API) |

Plus **Chatwoot** as a channel plugin (see [Plugins](plugins.md)), which fronts WhatsApp,
the web widget and more, with native human handoff. Channel plugins are configured on the
dashboard **Integrations** tab rather than **Channels**.

## Setup notes per channel

- **Slack.** Create an app, add a bot token scope, enable Event Subscriptions and point the
  request URL at the connection URL (Pepe answers the `url_verification` challenge). Add
  `message.channels` / `app_mention` events. The signing secret verifies each request.
- **Discord.** This uses the Interactions endpoint, not a gateway bot, so it responds to
  **slash commands** (add a command with a text option). Set the app's "Interactions
  Endpoint URL" to the connection URL; the app public key verifies the Ed25519 signature.
  The command is acknowledged immediately and the answer arrives as a follow-up.
- **Microsoft Teams.** Register a bot (Azure), set its messaging endpoint to the connection
  URL. Pepe replies to the activity's `serviceUrl` with a token minted from the app
  credentials. Keep the endpoint behind a proxy/secret (the inbound JWT is not validated
  here).
- **Google Chat.** Configure the app's webhook (HTTP) endpoint to the connection URL and
  provide an OAuth `access_token` for the Chat API; replies are posted back to the space.
  Keep the endpoint behind a proxy.

## Not built in

Signal, IRC and iMessage need a persistent connection or a platform-specific bridge that
doesn't fit the webhook model; they are out of scope for now. A new channel can always be
added as a channel [plugin](plugins.md).

---

[Back to the docs index](../README.md#documentation)
