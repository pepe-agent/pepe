# WebSocket

Connect to `ws://localhost:4000/socket/websocket` (Phoenix Socket protocol) and
join topic `agent:<name>` (`agent:default` for the default agent).

* push `"prompt"` `{ "text": "..." }` -> receive streamed `"delta"`, `"tool_call"`,
  `"tool_result"`, then `"done"` events.

* push `"reset"` to clear history.

Auth mirrors the [`/v1` API](http-api.md#access-tokens-per-company-or-per-agent): open until
tokens exist, then pass one as a **connect param** (a WebSocket can't set headers) -
`ws://localhost:4000/socket/websocket?token=pepe_...`. The token's scope is enforced on
`join`: a client can only join `agent:` topics its token allows (`agent:default`
resolves to the scope's default), and a company token joining another company's agent
is refused. Bare names qualify into the token's company (`agent:vendas` -> `acme/vendas`).

---

[Back to the docs index](../README.md#documentation)
