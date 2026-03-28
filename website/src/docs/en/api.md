---
title: HTTP API and WebSocket
description: Serve your agents over an OpenAI-compatible HTTP API and a streaming WebSocket. Point any OpenAI SDK at Pepe and treat each agent as a model.
---

Pepe serves your agents over an HTTP API that speaks the OpenAI Chat Completions protocol. Any tool or SDK that can talk to OpenAI can talk to Pepe with no code change: point its `base_url` at your Pepe server and use an agent name where you would normally put a model id. There is also a WebSocket for live, token-by-token streaming with tool-call visibility.

The two surfaces cover two needs. The HTTP API is the right default for request/response and server-to-server work. The WebSocket is for interactive UIs where you want to render tool calls and streamed text as they happen.

## A first call

Start the server, then send a chat completion. This works out of the box with no authentication (see [Authentication](#authentication-and-tokens) for locking it down):

```bash
pepe serve --port 4000
```

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "hello"}]
  }'
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
2. If no agent matches but the name matches a bare model connection, Pepe wraps it in a minimal pass-through agent (no tools, single turn) and calls that model directly. This fallback is only available in the open or root scope (see [Token scopes](#token-scopes)).
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

## Sessions: stateful vs stateless

By default the API is **stateless**: each request must carry the full message history, exactly like OpenAI. You send everything, Pepe answers, nothing is remembered.

Pepe also offers a **stateful** mode that most OpenAI servers do not. Attach a session id and the server keeps the conversation for you. On every later call you send only the newest user message; Pepe appends it to the stored history, runs the agent, and remembers the result. This is convenient for chat UIs and messaging bots where you do not want to ship the whole transcript each time.

You can pass the session id three ways. Pepe checks them in this order:

1. A `session_id` field in the JSON body.
2. The OpenAI-standard `user` field in the JSON body.
3. An `x-session-id` HTTP header.

The `user` route is the interesting one: `user` is a real field in the OpenAI chat-completions schema, so you can reuse it as the session key from any stock OpenAI SDK and get server-side memory without leaving the standard shape.

```bash
# Turn 1: only the new message is needed; the server keeps the history.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "My name is Ada."}]
  }'

# Turn 2: same session id, just the follow-up. The agent remembers "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "session_id": "user-42",
    "messages": [{"role": "user", "content": "What is my name?"}]
  }'
```

In stateful mode the response includes the `session_id` you used, so you can echo it back on the next call. Stateful sessions work with streaming too; just add `"stream": true`.

<div class="note"><strong>Tenancy isolation.</strong> Session keys are namespaced by company internally. The same session id used under two different tokens (two different companies) never reaches the same conversation, so one tenant can never read another tenant's session.</div>

To go stateless, simply omit all three id sources and send the full `messages` array yourself. That is the plain OpenAI behavior.

## Authentication and tokens

With **zero tokens configured, the API is open**. This is the single-tenant default: run it on your own machine or inside a trusted network and skip auth entirely.

Creating the first token flips a switch. Once any token exists, every request must present a valid one, or it is refused with `401`. There is no half-open state; the first token you mint locks the door.

### Minting and managing tokens

Tokens are created from the CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

A token is a random string prefixed `ctx_`. Only its SHA-256 hash is stored in the config file; the raw token is printed once at creation and never again. Copy it then. If you lose it, revoke it and mint a new one.

### Presenting a token

Send it either way an OpenAI-style client would:

```bash
# OpenAI standard: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

```bash
# Azure OpenAI style: api-key header (accepted as a fallback)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

Any OpenAI SDK sends the `Authorization: Bearer` form when you set its `api_key`, so authentication needs no special handling on the client.

### Token scopes

A token carries a scope that decides which agents it can reach. From narrowest to widest:

* **Agent-locked** (`--agent HANDLE`): always runs exactly that agent. The request `model` field is ignored. Hand this to a caller who should only ever reach one specific agent.
* **Company** (`--company CO`): any agent inside that company. A bare `model` name qualifies into that company automatically, and a request for an agent belonging to a different company is refused with `403`.
* **Neither**: the root scope (no company). This is what every command operates on when you do not scope it. It can reach root agents (those with a bare, un-namespaced name) and, uniquely, fall back to bare model connections by name.

`GET /v1/models` respects the scope: a company or agent token sees only its own agents, never another tenant's, and never the raw model connections.

## Multi-tenant routing: give company X its own access

Scopes are how you hand out API access per tenant. To give a company its own key, mint a company-scoped token:

```bash
pepe token add --company acme --label "Acme production"
# prints: ctx_9f2a... (copy it now, shown once)
```

A caller holding that token:

* can reach any agent that belongs to `acme`, by name;
* can send a bare `model` name and have it resolve inside `acme`;
* is refused with `403` if it names an agent in another company;
* sees only `acme` agents from `GET /v1/models`.

```bash
# Allowed: an agent inside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"hi"}] }'

# Refused with 403: an agent outside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-company-agent", "messages": [{"role":"user","content":"hi"}] }'
```

To pin a token to exactly one agent (the `model` field is then ignored entirely), add `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "Acme support widget"
```

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

## Listing models

```bash
curl http://localhost:4000/v1/models \
  -H 'authorization: Bearer ctx_your_token_here'
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

## Client examples

Every example points at the local server. Where a token is shown, drop it if your API is open.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hello"}] }'
```

**Node (plain fetch)**

```javascript
const res = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: {
    "content-type": "application/json",
    authorization: "Bearer ctx_your_token_here",
  },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "hello" }],
  }),
});
const data = await res.json();
console.log(data.choices[0].message.content);
```

**Node (openai SDK)**

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:4000/v1",
  apiKey: "ctx_your_token_here", // any non-empty string if your API is open
});

const completion = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hello" }],
});
console.log(completion.choices[0].message.content);
```

**Python (openai SDK)**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="ctx_your_token_here",  # any non-empty string if your API is open
)

completion = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hello"}],
)
print(completion.choices[0].message.content)
```

**Python (plain requests)**

```python
import requests

res = requests.post(
    "http://localhost:4000/v1/chat/completions",
    headers={"authorization": "Bearer ctx_your_token_here"},
    json={"model": "assistant", "messages": [{"role": "user", "content": "hello"}]},
)
print(res.json()["choices"][0]["message"]["content"])
```

**Ruby**

```ruby
require "net/http"
require "json"

uri = URI("http://localhost:4000/v1/chat/completions")
req = Net::HTTP::Post.new(uri)
req["content-type"] = "application/json"
req["authorization"] = "Bearer ctx_your_token_here"
req.body = { model: "assistant", messages: [{ role: "user", content: "hello" }] }.to_json

res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
puts JSON.parse(res.body)["choices"][0]["message"]["content"]
```

**PHP**

```php
<?php
$ch = curl_init("http://localhost:4000/v1/chat/completions");
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => [
        "content-type: application/json",
        "authorization: Bearer ctx_your_token_here",
    ],
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode([
        "model" => "assistant",
        "messages" => [["role" => "user", "content" => "hello"]],
    ]),
]);
$data = json_decode(curl_exec($ch), true);
echo $data["choices"][0]["message"]["content"], "\n";
```

**Java**

```java
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

var body = """
    { "model": "assistant", "messages": [{"role":"user","content":"hello"}] }
    """;

var request = HttpRequest.newBuilder(URI.create("http://localhost:4000/v1/chat/completions"))
    .header("content-type", "application/json")
    .header("authorization", "Bearer ctx_your_token_here")
    .POST(HttpRequest.BodyPublishers.ofString(body))
    .build();

var response = HttpClient.newHttpClient()
    .send(request, HttpResponse.BodyHandlers.ofString());
System.out.println(response.body());
```

**Elixir (using Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  headers: [{"authorization", "Bearer ctx_your_token_here"}],
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "hello"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```

## WebSocket: live streaming

The HTTP SSE stream above is enough for most server-to-server streaming, and it is simpler to consume. Reach for the WebSocket when you are building an interactive UI and want more than text: it surfaces each tool call and tool result as it happens, and it can push a fired watch notification back to the same connection.

### Connect

Connect at `ws://HOST:PORT/socket/websocket` (use `wss://` over TLS). Authentication mirrors the HTTP API: when tokens are required, pass the token as a query parameter, because browsers cannot set headers on a WebSocket:

```
ws://localhost:4000/socket/websocket?token=ctx_your_token_here
```

If your API is open, drop the `token` parameter.

### The frame protocol

The socket speaks a simple JSON framing protocol. Every message, in both directions, is a JSON array of five elements:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` and `ref` are strings you choose to correlate replies with requests. `topic` names what you are talking to. The lifecycle is: join a topic, send prompts, optionally reset, and send a heartbeat every 30 seconds or so to keep the connection alive.

```json
// 1. Join a topic. "agent:<name>", or "agent:default" for the default agent.
//    The join payload may carry a stable session to keep the same
//    notification channel across reconnects.
["1", "1", "agent:default", "phx_join", {}]

// 2. Send a prompt. The reply streams back as separate frames.
["1", "2", "agent:default", "prompt", { "text": "hello" }]

// 3. Reset the conversation history for this topic.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, every ~30s, so the connection is not dropped.
[null, "h", "phoenix", "heartbeat", {}]
```

Joining `agent:<name>` selects and authorizes that agent against your token scope, exactly like the `model` field over HTTP. A topic you are not allowed to join is refused. Pass `{"session": "some-stable-id"}` in the join payload to keep the same watch/notification channel across reconnects; otherwise a fresh per-connection id is used.

### Events

You **send** two inbound events:

* `prompt` with `{ "text": "..." }`: send a message and stream the reply.
* `reset` with `{}`: clear the conversation history.

You **receive** these outbound events, each arriving as a frame whose payload is shown:

* `delta` `{ "text": "..." }`: a streamed fragment of the answer.
* `tool_call` `{ "name": "...", "arguments": {...} }`: the agent is invoking a tool.
* `tool_result` `{ "name": "...", "output": "..." }`: that tool's output.
* `done` `{ "content": "..." }`: the final answer; the turn is complete.
* `watch` `{ "text": "..." }`: a watch created from this connection has fired.
* `error` `{ "reason": "..." }`: something went wrong on this turn.

### JavaScript (the phoenix client)

In JavaScript the ergonomic way to consume this is the `phoenix` npm package, which handles framing, refs, and heartbeats for you:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "ctx_your_token_here" }, // omit if your API is open
});
socket.connect();

const channel = socket.channel("agent:default", { session: "user-42" });
channel.join()
  .receive("ok", () => console.log("joined"))
  .receive("error", (err) => console.error("join failed", err));

channel.on("delta", ({ text }) => process.stdout.write(text));
channel.on("tool_call", ({ name, arguments: args }) =>
  console.log(`\n[tool ${name}]`, args));
channel.on("tool_result", ({ name, output }) =>
  console.log(`[tool ${name} result]`, output));
channel.on("done", ({ content }) => console.log("\n[final]", content));
channel.on("watch", ({ text }) => console.log("[watch]", text));
channel.on("error", ({ reason }) => console.error("[error]", reason));

channel.push("prompt", { text: "What files are in the current directory?" });
```

### Raw frames (any language)

Without the `phoenix` package, speak the frame protocol directly over any WebSocket client. This Python example joins, sends one prompt, prints streamed deltas, and stops when `done` arrives. Note the heartbeat you should send periodically on a long-lived connection.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=ctx_your_token_here"
)

# Join the default agent's topic.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Send a prompt.
ws.send(json.dumps(["1", "2", "agent:default", "prompt", {"text": "hello"}]))

while True:
    _join_ref, _ref, _topic, event, payload = json.loads(ws.recv())
    if event == "delta":
        print(payload["text"], end="", flush=True)
    elif event == "tool_call":
        print(f"\n[tool {payload['name']}] {payload['arguments']}")
    elif event == "done":
        print("\n[final]", payload["content"])
        break
    elif event == "error":
        print("\n[error]", payload["reason"])
        break

ws.close()
```

Send a heartbeat frame, `[null, "h", "phoenix", "heartbeat", {}]`, roughly every 30 seconds to keep a long-lived connection open.
