---
title: HTTP API
description: Call Pepe through the OpenAI-compatible Chat Completions API.
---

Pepe serves your agents over an HTTP API that speaks the OpenAI Chat Completions protocol. Any tool or SDK that can talk to OpenAI can talk to Pepe with no code change: point its `base_url` at your Pepe server and use an agent name where you would normally put a model id. You can also call the endpoint with plain HTTP requests from your own projects, websites, backends, jobs, or integrations; an LLM SDK is convenient, not required. There is also a WebSocket for live, token-by-token streaming with tool-call visibility.

The two surfaces cover two needs. The HTTP API is the right default for request/response and server-to-server work. The WebSocket is for interactive UIs where you want to render tool calls and streamed text as they happen.

## A first call

Start the server, then send a chat completion. This works out of the box with no authentication (see [Authentication](../auth/#authentication-and-tokens) for locking it down):

```bash
pepe serve --port 4000
```

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

**JavaScript**

```javascript
const response = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "hello" }]
  })
});

const data = await response.json();
console.log(data.choices[0].message.content);
```

**Python**

```python
import requests

response = requests.post(
    "http://localhost:4000/v1/chat/completions",
    json={
        "model": "assistant",
        "messages": [{"role": "user", "content": "hello"}],
    },
)

data = response.json()
print(data["choices"][0]["message"]["content"])
```

**PHP**

```php
$ch = curl_init("http://localhost:4000/v1/chat/completions");
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => ["content-type: application/json"],
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode([
        "model" => "assistant",
        "messages" => [["role" => "user", "content" => "hello"]],
    ]),
]);

$data = json_decode(curl_exec($ch), true);
echo $data["choices"][0]["message"]["content"];
```

**Elixir (using Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "hello"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```

The response is a standard OpenAI chat completion object:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion",
  "created": 1751800000,
  "model": "assistant",
  "choices": [
    {
      "index": 0,
      "message": { "role": "assistant", "content": "Hi! How can I help?" },
      "finish_reason": "stop"
    }
  ]
}
```

## Endpoints

There are two:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Both live under `/v1`, so a client configured with `base_url = http://HOST:PORT/v1` finds them exactly where an OpenAI client expects.

## The "model" field selects an agent

This is the one idea that makes everything else click. The `model` field in a chat request does not name a raw language model. It names a Pepe **agent**. When you send `"model": "assistant"`, Pepe runs the agent called `assistant`, with that agent's system prompt and its own set of tools. The agent runs the full tool-calling loop internally (call the model, run any tool calls, feed results back, repeat) and returns a single final answer in the usual completion shape.

Resolution of the `model` field happens in this order:

1. If the name matches an agent, that agent runs.
2. If no agent matches but the name matches a bare model connection, Pepe wraps it in a minimal pass-through agent (no tools, single turn) and calls that model directly. This fallback is only available in the open or root scope (see [Token scopes](../auth/#token-scopes)).
3. If neither matches, the default agent runs.

<div class="note"><strong>Practical upshot.</strong> The set of "models" a client can pick from is your set of agents. Give an agent a descriptive name, wire up its tools once, and every OpenAI-compatible client sees it as a selectable model.</div>

## Chat completions

### Non-streaming

Send `messages` in the OpenAI shape. You may include a `system` message; if you omit one, the agent's own system prompt is used automatically.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [
      {"role": "user", "content": "Summarize the README in one sentence."}
    ]
  }'
```

### Streaming (Server-Sent Events)

Set `"stream": true` to receive the answer as it is generated. The wire format is identical to OpenAI streaming: a sequence of `data:` lines, each carrying a `chat.completion.chunk` object, terminated by `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Each chunk looks like this, with the incremental text in `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

The final chunk carries an empty delta and `"finish_reason": "stop"`, followed by the sentinel line `data: [DONE]`. Because this matches OpenAI byte for byte, any OpenAI streaming client parses it without changes.

## Errors

Errors come back in the OpenAI error shape (a top-level `error` object with a `message`), so existing error handling works. The status codes:

* `401` when a token is required but missing or invalid.
* `403` when you name an agent that exists but is outside your token's scope.
* `400` when the `model` field resolves to no agent and no model at all.
* `502` when the agent or a stateful session errors while running.

The `401` from the auth layer carries the OpenAI `invalid_api_key` code:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

The scope and resolution errors (`400`, `403`, `502`) use a `pepe_error` type:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Health check

`GET /health` (also `/healthz`) is an unauthenticated liveness and readiness probe for load balancers and uptime checks. It is deliberately minimal and never lists agents or models, so it leaks no tenant data:

```bash
curl http://localhost:4000/health
```

```json
{ "status": "ok", "service": "pepe", "ready": true }
```

`ready` is `true` once at least one model connection and one agent exist, so the service can actually answer. To discover which agents and models a caller can reach, use `GET /v1/models` below, which is authenticated and scoped.

## Listing models

`GET /v1/models` returns the agents (and, in the open or root scope, raw model connections) the caller can reach, in the OpenAI models shape. This is the scoped, per-company way to discover what is available: with a company token it lists only that company's agents, never another tenant's, and never the raw model connections.

```bash
curl http://localhost:4000/v1/models \
  -H 'authorization: Bearer pepe_your_token_here'
```

```json
{
  "object": "list",
  "data": [
    { "id": "assistant", "object": "model", "created": 0, "owned_by": "pepe:agent" },
    { "id": "support",   "object": "model", "created": 0, "owned_by": "pepe:agent" }
  ]
}
```

Agents are tagged `pepe:agent`. In the open or root scope, raw model connections also appear, tagged `pepe:model`. Because this is a standard models list, OpenAI tooling that offers a model picker populates it with your agents.
