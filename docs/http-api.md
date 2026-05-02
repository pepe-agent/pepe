# OpenAI-compatible HTTP API

```bash
mix pepe serve         # or: PHX_SERVER=true mix phx.server
```

```bash
# The "model" field selects an Pepe AGENT by name (so its tools/persona apply);
# falls back to a bare model connection, then the default agent.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hello"}]}'

# streaming (Server-Sent Events)
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","stream":true,"messages":[{"role":"user","content":"hi"}]}'

curl http://localhost:4000/v1/models
curl http://localhost:4000/health
```

Works with the official OpenAI SDKs - just set the base URL to
`http://localhost:4000/v1` and the model to your agent's name.

### Access tokens (per company or per agent)

With **no tokens configured, the `/v1` API answers only same-machine (loopback)
callers**: a local `curl` works with no token, but any remote caller is refused with
`401`, so a network-exposed server is never anonymous. Creating the first token flips
the switch for everyone: from then on every call, local or remote, needs a valid
`Authorization: Bearer pepe_...`. A token is stored only as a SHA-256 hash (the raw
value is shown once), and its scope decides what it can reach:

| Scope | Created with | Can call |
| --- | --- | --- |
| **Agent** | `--agent HANDLE` | only that agent (the `model` field is ignored) |
| **Company** | `--company CO` | any agent in that company (bare names qualify into it); other companies -> `403` |
| **Root** | neither | root agents + bare model connections |

```bash
mix pepe token add --company acme --label "acme mobile app"   # prints pepe_... once
mix pepe token add --agent acme/vendas --label "single integration"
mix pepe token list       # id · fingerprint · scope · label
mix pepe token revoke <id>

# then callers must authenticate
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_...' \
  -H 'content-type: application/json' \
  -d '{"model":"vendas","messages":[{"role":"user","content":"oi"}]}'   # "vendas" -> acme/vendas
```

The token is read from `Authorization: Bearer ...` (the OpenAI standard, what the
official SDKs send) or, as a fallback, the Azure-style `api-key: ...` header.

`GET /v1/models` is filtered to the token's scope, so a client only ever sees the
agents it may use. This is what makes the [company isolation](companies.md)
real over the network: a remote caller reaches exactly the agents its token allows.

### Stateful sessions

By default the endpoint is stateless (you send the full `messages` array each
time, like OpenAI). Pass a **session id** and the server keeps the whole
conversation for you - then you only need to send the latest user message.

Two dimensions, combined into the session key:

* `"user": "abc"` - **who** is talking. The standard OpenAI field, so a plain OpenAI
  SDK keeps a conversation with no Pepe-specific field.

* `"session_id": "xyz"` in the JSON body (or an `X-Session-Id: xyz` header) - **which**
  conversation of theirs.

How they combine:

| Sent | Session key |
| --- | --- |
| `user` only | `abc` |
| `session_id` only | `xyz` |
| both | `abc:xyz` (independent threads per user) |
| both, same value | deduped to one |
| neither (or blank) | stateless |

So on WhatsApp you can pass `user` = the phone number and `session_id` = a thread id,
and each thread of each contact is its own conversation.

```bash
# turn 1
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"my name is John Doe"}]}'

# turn 2 - same "user", server remembers turn 1
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"what is my name?"}]}'
```

Each session is its own supervised process, keyed by `api:<id>`
(`Pepe.Agent.Session`). Streaming works with sessions too. WebSocket and Telegram are stateful by design
(per-connection / per-chat-id). An empty `user`/`session_id` (`""`) is treated as
stateless.

---

[Back to the docs index](../README.md#documentation)
