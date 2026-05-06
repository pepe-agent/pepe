# WhatsApp (Meta Cloud API)

Connect **official WhatsApp** numbers via Meta's Cloud API. Unlike Telegram (which
Pepe polls), WhatsApp **pushes** inbound messages to a webhook, so each connection
gets its own URL:

```
/webhooks/:company/:provider/:slug        e.g.  /webhooks/acme/whatsapp/support
```

This is one generic webhook surface (a provider registry: WhatsApp today, others
later), not WhatsApp-specific plumbing. The `:company` segment is `root` for the
no-company scope. `GET` answers Meta's verification handshake; `POST` is an inbound
message: its `X-Hub-Signature-256` is verified against the app secret, then the
bound agent runs and the reply is sent back over the Graph API. Served by
`mix pepe serve` (no extra process).

You can run **as many connections as you like**, each bound to an agent, the
webhook analogue of Telegram's multi-bot. A connection has a **mode**:

| | **admin** (yours) | **support** (customer-facing) |
|---|---|---|
| Slash commands | on (`/new` resets) | off (treated as text) |
| Who may message | `allowed_numbers` (your number) | anyone |
| Learns? (`trainers`) | you're a trainer | `[]` - never learns from a customer |
| Agent tools | full | keep it locked (safe tools only, no human to approve) |
| Session | kept | ephemeral + idle TTL |

```bash
# add a support number (tokens default to ${WA_TOKEN_<SLUG>} / ${WA_APP_SECRET_<SLUG>})
mix pepe gateway whatsapp add support \
  --agent acme/support --company acme --mode support \
  --phone-number-id 123456789 --ttl-min 30
mix pepe gateway whatsapp list                 # connections + their Callback URLs
mix pepe gateway whatsapp set-agent support acme/sales
mix pepe gateway whatsapp remove support
```

...or add one from the **Channels** tab in the dashboard. Then register the printed
Callback URL and verify token in your Meta app (subscribe the `messages` field).

**On the Meta side** (once per number): create an app -> add WhatsApp -> note the
`phone_number_id`, generate a permanent access token (`${WA_TOKEN_<SLUG>}`), copy the
App Secret (`${WA_APP_SECRET_<SLUG>}`), and point the Callback URL at your slug.

**The session** is keyed `whatsapp:<agent>:<phone>`, the agent's thread with that
customer, isolated per company via the agent handle. Two things end it: the agent
calls the **`end_session`** tool when the exchange is done (clears the context for
the next message), or the **idle TTL** (`--ttl-min`, unset = never) evicts a quiet
session. Dynamic routing to a specialist is just the agent using `send_to_agent`
(see **Agent-to-agent routing**).

> **24-hour window.** Meta only allows free-form replies within 24h of the
> customer's last message. Reactive support fits; proactive sends outside the window
> need pre-approved templates (not handled here).

---

[Back to the docs index](../README.md#documentation)
