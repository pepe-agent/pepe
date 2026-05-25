---
title: WebSocket
description: Transmite eventos de agentes ao vivo por uma ligação WebSocket.
---

## WebSocket: streaming ao vivo

O stream SSE por HTTP acima já chega para a maior parte do streaming servidor-a-servidor, e é mais simples de consumir. Recorre ao WebSocket quando estiveres a construir uma interface interativa e quiseres mais do que texto: revela cada chamada de ferramenta e cada resultado de ferramenta à medida que acontece, e consegue empurrar uma notificação de vigilância disparada de volta para a mesma ligação.

### Ligar

Liga em `ws://HOST:PORT/socket/websocket` (usa `wss://` sobre TLS). A autenticação espelha a API HTTP: quando são exigidos tokens, passa o token como parâmetro de query, porque os navegadores não conseguem definir cabeçalhos num WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Se a tua API estiver aberta, omite o parâmetro `token`.

### O protocolo de frames

O socket fala um protocolo simples de framing em JSON. Cada mensagem, em ambas as direções, é um array JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` e `ref` são strings que escolhes para correlacionar respostas com pedidos. `topic` nomeia com quem estás a falar. O ciclo de vida é: entrar num topic, enviar prompts, opcionalmente reiniciar, e enviar um heartbeat a cada 30 segundos ou assim para manter a ligação viva.

```json
// 1. Entra num topic. "agent:<name>", ou "agent:default" para o agente predefinido.
//    O payload de entrada pode transportar uma sessão estável para manter o mesmo
//    canal de notificações entre reconexões.
["1", "1", "agent:default", "phx_join", {}]

// 2. Envia um prompt. A resposta chega em frames separados.
["1", "2", "agent:default", "prompt", { "text": "hello" }]

// 3. Reinicia o histórico da conversa para este topic.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, a cada ~30s, para a ligação não ser derrubada.
[null, "h", "phoenix", "heartbeat", {}]
```

Entrar em `agent:<name>` seleciona e autoriza esse agente contra o âmbito do teu token, exatamente como o campo `model` sobre HTTP. O âmbito é aplicado no `join`, por isso um topic que o teu token não permite é recusado logo aí. `agent:default` resolve para o agente predefinido do âmbito do teu token. Um nome simples é qualificado dentro do projeto do teu token, por isso um token com âmbito `acme` que entra em `agent:sales` chega a `acme/sales`, e um token de projeto que tente entrar no agente de outro projeto é recusado. Passa `{"session": "some-stable-id"}` no payload de entrada para manter o mesmo canal de vigilância/notificações entre reconexões; caso contrário é usado um id novo por ligação. Passa também `{"lang": "pt-PT"}` e isso empurra a primeira resposta do agente para esse idioma (uma dica de sistema única, apenas no primeiro turno da sessão). É assim que o atributo `data-lang` do [widget incorporável](../widget/) chega ao agente.

### Eventos

**Envias** dois eventos de entrada:

* `prompt` com `{ "text": "..." }`: envia uma mensagem e recebe a resposta em streaming.
* `reset` com `{}`: limpa o histórico da conversa.

**Recebes** estes eventos de saída, cada um chegando como um frame cujo payload é mostrado:

* `delta` `{ "text": "..." }`: um fragmento em streaming da resposta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: o agente está a invocar uma ferramenta.
* `tool_result` `{ "name": "...", "output": "..." }`: a saída dessa ferramenta.
* `done` `{ "content": "..." }`: a resposta final; o turno está completo.
* `session_ended` `{}`: o agente chamou `end_session`; a resposta de fecho já
  chegou pelo `done` acima, e o *próximo* prompt começa com contexto novo.
* `watch` `{ "text": "..." }`: uma vigilância criada a partir desta ligação disparou.
* `error` `{ "reason": "..." }`: algo correu mal neste turno.

### JavaScript (o cliente phoenix)

Em JavaScript a forma ergonómica de consumir isto é o pacote npm `phoenix`, que trata do framing, dos refs e dos heartbeats por ti:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "pepe_your_token_here" }, // omite se a tua API estiver aberta
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
channel.on("session_ended", () => console.log("[sessão terminada]"));
channel.on("watch", ({ text }) => console.log("[watch]", text));
channel.on("error", ({ reason }) => console.error("[error]", reason));

channel.push("prompt", { text: "What files are in the current directory?" });
```

### Frames em bruto (qualquer linguagem)

Sem o pacote `phoenix`, fala o protocolo de frames diretamente sobre qualquer cliente WebSocket. Este exemplo em Python entra, envia um prompt, imprime os deltas em streaming e para quando `done` chega. Repara no heartbeat que deves enviar periodicamente numa ligação de longa duração.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=pepe_your_token_here"
)

# Entra no topic do agente predefinido.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Envia um prompt.
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

Envia um frame de heartbeat, `[null, "h", "phoenix", "heartbeat", {}]`, a cada 30 segundos aproximadamente, para manter uma ligação de longa duração aberta.
