---
title: WebSocket
description: Receba eventos de um agente em tempo real por uma conexão WebSocket.
---

## WebSocket: streaming ao vivo

O WebSocket é para quem está construindo uma interface interativa que
mostra o agente trabalhando em tempo real: ele transmite a resposta
conforme ela é gerada, revela cada chamada de ferramenta e cada resultado
assim que acontecem, e ainda consegue empurrar de volta, pela mesma
conexão, a notificação de uma vigia que acabou de disparar. Para um
streaming mais simples, de servidor para servidor, o stream SSE da [API
HTTP](../api/) já costuma bastar, e é bem mais direto de consumir.

### Conectando

A conexão se faz em `ws://HOST:PORT/socket/websocket` (use `wss://` sobre
TLS). A autenticação segue o mesmo padrão da API HTTP, só que passando o
token como parâmetro de consulta em vez de cabeçalho, já que o navegador
não tem como definir cabeçalhos num WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Se a sua API estiver aberta, simplesmente não inclua o parâmetro `token`.

### O protocolo de frames

O socket fala um protocolo simples de frames em JSON. Toda mensagem, indo
ou vindo, é um array JSON com cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` e `ref` são strings escolhidas por você para correlacionar
requisições com suas respectivas respostas, e `topic` diz com quem você
está falando. O ciclo de vida da conexão é simples: entrar num tópico,
mandar prompts, opcionalmente reiniciar a conversa, e mandar um heartbeat a
cada 30 segundos ou perto disso, para manter a conexão viva.

```json
// 1. Entra num tópico. "agent:<nome>", ou "agent:default" para o agente padrão.
//    O payload de entrada pode carregar uma sessão estável, para manter o
//    mesmo canal de notificações entre reconexões.
["1", "1", "agent:default", "phx_join", {}]

// 2. Manda um prompt. A resposta volta em streaming, como frames separados.
["1", "2", "agent:default", "prompt", { "text": "olá" }]

// 3. Reinicia o histórico da conversa deste tópico.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, a cada ~30s, para a conexão não cair.
[null, "h", "phoenix", "heartbeat", {}]
```

Entrar em `agent:<nome>` seleciona e autoriza aquele agente específico
dentro do escopo do seu token, do mesmo jeito que o campo `model` faz por
HTTP. Essa checagem de escopo acontece no próprio `join`, então um tópico
fora do alcance do seu token já é recusado ali mesmo, sem chegar a lugar
nenhum. `agent:default` sempre resolve para o agente padrão do escopo do
seu token, e um nome simples é automaticamente qualificado dentro do
projeto desse token: um token com escopo `acme` que entra em `agent:sales`
chega, na prática, em `acme/sales`, e um token de projeto que tenta entrar
no agente de outro projeto é recusado. Passando `{"session":
"some-stable-id"}` no payload de entrada, o mesmo canal de
vigias/notificações é mantido entre reconexões; sem isso, um id novo é
gerado a cada conexão. Passar `{"lang": "pt-BR"}` também tem efeito: isso
inclina a primeiríssima resposta do agente para esse idioma, como uma dica
de sistema única, só no primeiro turno da sessão. É exatamente assim que o
atributo `data-lang` do [widget incorporável](../widget/) chega até o
agente.

### Eventos

Você **envia** dois eventos, de entrada:

* `prompt` com `{ "text": "..." }`: manda uma mensagem e recebe a resposta
  em streaming.
* `reset` com `{}`: limpa o histórico da conversa.

E **recebe** estes eventos de saída, cada um chegando como um frame com o
payload indicado:

* `delta` `{ "text": "..." }`: um fragmento em streaming da resposta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: o agente está
  chamando uma ferramenta.
* `tool_result` `{ "name": "...", "output": "..." }`: a saída daquela
  ferramenta.
* `done` `{ "content": "..." }`: a resposta final; o turno terminou.
* `session_ended` `{}`: o agente chamou `end_session`; a resposta de
  encerramento já chegou pelo `done` acima, e o *próximo* prompt começa com
  um contexto todo novo.
* `watch` `{ "text": "..." }`: uma vigia criada a partir dessa conexão
  acabou de disparar.
* `error` `{ "reason": "..." }`: algo deu errado nesse turno.

### JavaScript (o cliente phoenix)

Em JavaScript, o jeito mais prático de consumir tudo isso é o pacote npm
`phoenix`, que já cuida sozinho de frames, refs e heartbeats:

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "pepe_your_token_here" }, // omita se sua API estiver aberta
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

### Frames crus (em qualquer linguagem)

Sem o pacote `phoenix`, dá para falar o protocolo de frames diretamente com
qualquer cliente WebSocket. O exemplo em Python abaixo entra no tópico,
manda um prompt, imprime os deltas conforme chegam em streaming e para
assim que o `done` aparece. Repare no heartbeat que precisa ser mandado de
tempos em tempos numa conexão de longa duração.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=pepe_your_token_here"
)

# Entra no tópico do agente padrão.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Manda um prompt.
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

Mande um frame de heartbeat, `[null, "h", "phoenix", "heartbeat", {}]`,
mais ou menos a cada 30 segundos, para manter uma conexão de longa duração
aberta.
