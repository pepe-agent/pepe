---
title: WebSocket
description: Transmite ao vivo os eventos de um agente através de uma ligação WebSocket.
---

## WebSocket: streaming ao vivo

O WebSocket é para quem quer construir interfaces interativas que mostrem um agente a trabalhar em tempo real: transmite a resposta à medida que é gerada, revela cada chamada de ferramenta e o respetivo resultado assim que acontecem, e ainda consegue empurrar de volta, para a mesma ligação, uma notificação de vigilância que tenha disparado. Para um streaming simples de servidor para servidor, basta normalmente o stream SSE da [API HTTP](../api/), que é mais simples de consumir.

### Ligar

A ligação faz-se em `ws://HOST:PORT/socket/websocket` (usa `wss://` sobre TLS). A autenticação espelha a da API HTTP, com uma diferença: quando são exigidos tokens, o token vai como parâmetro de query, já que um navegador não consegue definir cabeçalhos num WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Se a tua API estiver aberta, basta omitir o parâmetro `token`.

### O protocolo de frames

O socket fala um protocolo simples de framing em JSON: em qualquer direção, cada mensagem é um array JSON de cinco elementos.

```
[join_ref, ref, topic, event, payload]
```

`join_ref` e `ref` são strings à tua escolha, usadas para correlacionar pedidos com respostas, e `topic` nomeia com quem estás a falar. O ciclo de vida é simples: entras num topic, envias prompts, opcionalmente reinicias, e vais enviando um heartbeat a cada 30 segundos ou por aí para manter a ligação viva.

```json
// 1. Entra num topic. "agent:<name>", ou "agent:default" para o agente predefinido.
//    O payload de entrada pode transportar uma sessão estável, para manter o mesmo
//    canal de notificações entre reconexões.
["1", "1", "agent:default", "phx_join", {}]

// 2. Envia um prompt. A resposta chega em frames separados.
["1", "2", "agent:default", "prompt", { "text": "hello" }]

// 3. Reinicia o histórico da conversa deste topic.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, a cada ~30s, para a ligação não cair.
[null, "h", "phoenix", "heartbeat", {}]
```

Entrar em `agent:<name>` seleciona e autoriza esse agente dentro do âmbito do teu token, exatamente como o campo `model` faz sobre HTTP, com a diferença de que aqui o âmbito é validado logo no `join`: um topic que o teu token não alcance é recusado ali mesmo. `agent:default` resolve sempre para o agente predefinido do âmbito do teu token, e um nome simples é qualificado dentro do projeto desse token, por isso um token com âmbito `acme` que entra em `agent:sales` chega a `acme/sales`, enquanto um token de projeto que tente entrar no agente de outro projeto é recusado. Passa `{"session": "some-stable-id"}` no payload de entrada para manteres o mesmo canal de vigilâncias e notificações entre reconexões; sem isso, é gerado um id novo a cada ligação. Passa também `{"lang": "pt-PT"}` e a primeira resposta do agente já se inclina para esse idioma, uma dica de sistema que só é aplicada uma vez, no primeiro turno da sessão. É assim que o atributo `data-lang` do [widget incorporável](../widget/) chega até ao agente.

### Eventos

Há dois eventos de entrada que **enviamos**:

* `prompt` com `{ "text": "..." }`: envia uma mensagem e recebe a resposta em streaming.
* `reset` com `{}`: limpa o histórico da conversa.

E estes são os eventos de saída que **recebemos**, cada um a chegar como um frame cujo payload se mostra a seguir:

* `delta` `{ "text": "..." }`: um fragmento em streaming da resposta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: o agente está a invocar uma ferramenta.
* `tool_result` `{ "name": "...", "output": "..." }`: a saída dessa ferramenta.
* `done` `{ "content": "..." }`: a resposta final; o turno terminou.
* `session_ended` `{}`: o agente chamou `end_session`; a resposta de despedida já chegou pelo `done` anterior, e o *próximo* prompt arranca com contexto novo.
* `watch` `{ "text": "..." }`: uma vigilância criada a partir desta ligação disparou.
* `error` `{ "reason": "..." }`: algo correu mal neste turno.

### JavaScript (o cliente phoenix)

Em JavaScript, a forma mais ergonómica de consumir isto é o pacote npm `phoenix`, que já trata do framing, dos refs e dos heartbeats por ti:

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

Sem o pacote `phoenix`, também dá para falar o protocolo de frames diretamente sobre qualquer cliente WebSocket. Este exemplo em Python entra no topic, envia um prompt, imprime os deltas à medida que chegam em streaming, e para assim que recebe `done`. Repara no heartbeat que deves enviar de tempos a tempos numa ligação de longa duração.

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

Para manter uma ligação de longa duração aberta, envia um frame de heartbeat, `[null, "h", "phoenix", "heartbeat", {}]`, a cada 30 segundos, aproximadamente.
