---
title: WebSocket
description: Transmita eventos de agentes ao vivo por uma conexão WebSocket.
---

## WebSocket: streaming ao vivo

O stream SSE por HTTP acima já basta para a maior parte do streaming de servidor a servidor e é mais simples de consumir. Recorra ao WebSocket quando estiver construindo uma interface interativa e quiser mais do que texto: ele revela cada chamada de ferramenta e cada resultado de ferramenta conforme acontece, e consegue empurrar uma notificação de vigilância disparada de volta para a mesma conexão.

### Conectar

Conecte em `ws://HOST:PORT/socket/websocket` (use `wss://` sobre TLS). A autenticação espelha a API HTTP: quando tokens são exigidos, passe o token como parâmetro de consulta, porque os navegadores não conseguem definir cabeçalhos em um WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Se a sua API estiver aberta, remova o parâmetro `token`.

### O protocolo de frames

O socket fala um protocolo simples de frames JSON. Cada mensagem, nas duas direções, é um array JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` e `ref` são strings que você escolhe para correlacionar respostas com requisições. `topic` nomeia com o que você está conversando. O ciclo de vida é: entrar em um tópico, enviar prompts, opcionalmente reiniciar, e enviar um heartbeat a cada 30 segundos, mais ou menos, para manter a conexão viva.

```json
// 1. Join a topic. "agent:<name>", or "agent:default" for the default agent.
//    The join payload may carry a stable session to keep the same
//    notification channel across reconnects.
["1", "1", "agent:default", "phx_join", {}]

// 2. Send a prompt. The reply streams back as separate frames.
["1", "2", "agent:default", "prompt", { "text": "olá" }]

// 3. Reinicia o histórico da conversa deste tópico.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, every ~30s, so the connection is not dropped.
[null, "h", "phoenix", "heartbeat", {}]
```

Entrar em `agent:<name>` seleciona e autoriza aquele agente contra o escopo do seu token, exatamente como o campo `model` por HTTP. O escopo é aplicado no `join`, então um tópico que o seu token não permite é recusado ali mesmo. `agent:default` resolve para o agente padrão do escopo do seu token. Um nome simples é qualificado dentro do projeto do seu token, então um token com escopo `acme` que entra em `agent:sales` chega em `acme/sales`, e um token de projeto que tenta entrar no agente de outro projeto é recusado. Passe `{"session": "some-stable-id"}` no payload de entrada para manter o mesmo canal de vigilância/notificação entre reconexões; caso contrário, um id novo por conexão é usado. Passe também `{"lang": "pt-BR"}` e isso inclina a primeira resposta do agente para esse idioma (uma dica de sistema única, no primeiro turno da sessão). É assim que o atributo `data-lang` do [widget incorporável](../widget/) chega ao agente.

### Eventos

Você **envia** dois eventos de entrada:

* `prompt` com `{ "text": "..." }`: envia uma mensagem e transmite a resposta.
* `reset` com `{}`: limpa o histórico da conversa.

Você **recebe** estes eventos de saída, cada um chegando como um frame cujo payload é mostrado:

* `delta` `{ "text": "..." }`: um fragmento em streaming da resposta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: o agente está invocando uma ferramenta.
* `tool_result` `{ "name": "...", "output": "..." }`: a saída daquela ferramenta.
* `done` `{ "content": "..." }`: a resposta final; o turno está completo.
* `session_ended` `{}`: o agente chamou `end_session`; a resposta de fechamento já
  chegou pelo `done` acima, e o *próximo* prompt começa com contexto novo.
* `watch` `{ "text": "..." }`: uma vigilância criada a partir desta conexão foi disparada.
* `error` `{ "reason": "..." }`: algo deu errado neste turno.

### JavaScript (o cliente phoenix)

Em JavaScript a forma ergonômica de consumir isso é o pacote npm `phoenix`, que cuida dos frames, dos refs e dos heartbeats para você:

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
channel.on("session_ended", () => console.log("[sessão encerrada]"));
channel.on("watch", ({ text }) => console.log("[watch]", text));
channel.on("error", ({ reason }) => console.error("[error]", reason));

channel.push("prompt", { text: "Quais arquivos existem no diretório atual?" });
```

### Frames crus (qualquer linguagem)

Sem o pacote `phoenix`, fale o protocolo de frames diretamente sobre qualquer cliente WebSocket. Este exemplo em Python entra, envia um prompt, imprime os deltas em streaming e para quando `done` chega. Repare no heartbeat que você deve enviar periodicamente em uma conexão de longa duração.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=pepe_your_token_here"
)

# Join the default agent's topic.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Send a prompt.
ws.send(json.dumps(["1", "2", "agent:default", "prompt", {"text": "olá"}]))

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

Envie um frame de heartbeat, `[null, "h", "phoenix", "heartbeat", {}]`, mais ou menos a cada 30 segundos para manter aberta uma conexão de longa duração.
