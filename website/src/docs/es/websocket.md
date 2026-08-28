---
title: WebSocket
description: Transmite eventos de agente en vivo a través de una conexión WebSocket.
---

## WebSocket: streaming en vivo

El WebSocket sirve para construir interfaces interactivas que muestren a un agente trabajando en tiempo real: transmite la respuesta a medida que se va generando, deja ver cada llamada a herramienta y su resultado en el momento en que ocurren, y puede empujar hacia esa misma conexión la notificación de una vigilancia que se disparó. Para un streaming simple entre servidores, el stream SSE de la [API HTTP](../api/) suele bastar, y además es más fácil de consumir.

### Conectarse

Conéctate a `ws://HOST:PORT/socket/websocket` (usa `wss://` si va sobre TLS). La autenticación funciona igual que en la API HTTP: cuando se exige token, pásalo como parámetro de consulta, porque un navegador no puede fijar cabeceras al abrir un WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Si tu API está abierta, simplemente omite el parámetro `token`.

### El protocolo de tramas

El socket habla un protocolo de tramas en JSON bastante simple. Cada mensaje, en cualquiera de las dos direcciones, es un arreglo JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` y `ref` son cadenas que tú eliges, para poder relacionar cada respuesta con su petición. `topic` indica con quién estás hablando. El ciclo de vida es: unirte a un tópico, mandar prompts, opcionalmente reiniciar, y mandar un latido cada 30 segundos más o menos para que la conexión siga viva.

```json
// 1. Join a topic. "agent:<name>", or "agent:default" for the default agent.
//    The join payload may carry a stable session to keep the same
//    notification channel across reconnects.
["1", "1", "agent:default", "phx_join", {}]

// 2. Send a prompt. The reply streams back as separate frames.
["1", "2", "agent:default", "prompt", { "text": "hola" }]

// 3. Reset the conversation history for this topic.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, every ~30s, so the connection is not dropped.
[null, "h", "phoenix", "heartbeat", {}]
```

Unirte a `agent:<name>` selecciona y autoriza ese agente dentro del alcance de tu token, exactamente igual que el campo `model` en la API HTTP. Ese alcance se verifica justo al hacer el `join`, así que un tópico que tu token no tiene permitido se rechaza ahí mismo. `agent:default` resuelve al agente predeterminado dentro del alcance de tu token. Un nombre suelto se completa con el proyecto de tu token, de modo que un token con alcance `acme` que se une a `agent:sales` termina llegando a `acme/sales`, y un token de proyecto que intente unirse al agente de otro proyecto se rechaza. Pasa `{"session": "some-stable-id"}` en el payload del join si quieres conservar el mismo canal de vigilancias/notificaciones a través de reconexiones; si no, se usa un id nuevo en cada conexión. También puedes pasar `{"lang": "pt-BR"}`, y eso empuja la primera respuesta del agente hacia ese idioma (es un aviso de sistema que se manda una sola vez, en el primer turno de la sesión). Así es, justamente, como el atributo `data-lang` del [widget incrustable](../widget/) le llega al agente.

### Eventos

**Mandas** dos eventos de entrada:

* `prompt` con `{ "text": "..." }`: envía un mensaje y transmite la respuesta.
* `reset` con `{}`: borra el historial de la conversación.

**Recibes** estos eventos de salida, cada uno como una trama con el payload que se indica:

* `delta` `{ "text": "..." }`: un fragmento de la respuesta, en streaming.
* `tool_call` `{ "name": "...", "arguments": {...} }`: el agente está invocando una herramienta.
* `tool_result` `{ "name": "...", "output": "..." }`: la salida de esa herramienta.
* `done` `{ "content": "..." }`: la respuesta final; el turno terminó.
* `session_ended` `{}`: el agente llamó a `end_session`. Su respuesta de cierre ya llegó en el
  `done` anterior, y el prompt *siguiente* arranca con un contexto en blanco.
* `watch` `{ "text": "..." }`: se disparó una vigilancia creada desde esta conexión.
* `error` `{ "reason": "..." }`: algo falló en este turno.

### JavaScript (el cliente phoenix)

En JavaScript, la manera más cómoda de consumir esto es el paquete npm `phoenix`, que se ocupa por ti de las tramas, los refs y los latidos:

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
channel.on("session_ended", () => console.log("[sesión terminada]"));
channel.on("watch", ({ text }) => console.log("[watch]", text));
channel.on("error", ({ reason }) => console.error("[error]", reason));

channel.push("prompt", { text: "What files are in the current directory?" });
```

### Tramas crudas (en cualquier lenguaje)

Sin el paquete `phoenix`, puedes hablar el protocolo de tramas directamente desde cualquier cliente WebSocket. Este ejemplo en Python se une, manda un prompt, imprime los fragmentos que van llegando y se detiene al recibir `done`. Nota el latido que conviene mandar cada tanto en una conexión de larga duración.

```python
import json
import websocket  # pip install websocket-client

ws = websocket.create_connection(
    "ws://localhost:4000/socket/websocket?token=pepe_your_token_here"
)

# Join the default agent's topic.
ws.send(json.dumps(["1", "1", "agent:default", "phx_join", {}]))

# Send a prompt.
ws.send(json.dumps(["1", "2", "agent:default", "prompt", {"text": "hola"}]))

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

Manda una trama de latido, `[null, "h", "phoenix", "heartbeat", {}]`, más o menos cada 30 segundos, para mantener abierta una conexión de larga duración.
