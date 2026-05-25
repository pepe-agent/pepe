---
title: WebSocket
description: Stream live agent events over a WebSocket connection.
---

## WebSocket: live streaming

The HTTP SSE stream above is enough for most server-to-server streaming, and it is simpler to consume. Reach for the WebSocket when you are building an interactive UI and want more than text: it surfaces each tool call and tool result as it happens, and it can push a fired watch notification back to the same connection.

### Connect

Connect at `ws://HOST:PORT/socket/websocket` (use `wss://` over TLS). Authentication mirrors the HTTP API: when tokens are required, pass the token as a query parameter, because browsers cannot set headers on a WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
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

Joining `agent:<name>` selects and authorizes that agent against your token scope, exactly like the `model` field over HTTP. The scope is enforced on `join`, so a topic your token does not allow is refused there and then. `agent:default` resolves to the default agent of your token's scope. A bare name is qualified into your token's project, so a token scoped to `acme` that joins `agent:sales` reaches `acme/sales`, and a project token that tries to join another project's agent is refused. Pass `{"session": "some-stable-id"}` in the join payload to keep the same watch/notification channel across reconnects; otherwise a fresh per-connection id is used. Pass `{"lang": "pt-BR"}` too and it nudges the agent's very first reply toward that language (a one-time system hint on the session's first turn). This is how the [embeddable widget](../widget/)'s `data-lang` reaches the agent.

### Events

You **send** two inbound events:

* `prompt` with `{ "text": "..." }`: send a message and stream the reply.
* `reset` with `{}`: clear the conversation history.

You **receive** these outbound events, each arriving as a frame whose payload is shown:

* `delta` `{ "text": "..." }`: a streamed fragment of the answer.
* `tool_call` `{ "name": "...", "arguments": {...} }`: the agent is invoking a tool.
* `tool_result` `{ "name": "...", "output": "..." }`: that tool's output.
* `done` `{ "content": "..." }`: the final answer; the turn is complete.
* `session_ended` `{}`: the agent called `end_session`; its closing reply already
  arrived via the `done` above, and the *next* prompt starts on a fresh context.
* `watch` `{ "text": "..." }`: a watch created from this connection has fired.
* `error` `{ "reason": "..." }`: something went wrong on this turn.

### JavaScript (the phoenix client)

In JavaScript the ergonomic way to consume this is the `phoenix` npm package, which handles framing, refs, and heartbeats for you:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "pepe_your_token_here" }, // omit if your API is open
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
channel.on("session_ended", () => console.log("[session ended]"));
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
    "ws://localhost:4000/socket/websocket?token=pepe_your_token_here"
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
