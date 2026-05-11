---
title: WebSocket
description: Transmite eventos de agente en vivo mediante una conexión WebSocket.
---

## WebSocket: streaming en vivo

El stream SSE por HTTP de arriba es suficiente para la mayoría del streaming de servidor a servidor, y es más simple de consumir. Recurre al WebSocket cuando estás construyendo una interfaz interactiva y quieres más que texto: revela cada llamada a herramienta y cada resultado de herramienta a medida que ocurre, y puede empujar una notificación de vigilancia disparada de vuelta a la misma conexión.

### Conectar

Conéctate en `ws://HOST:PORT/socket/websocket` (usa `wss://` sobre TLS). La autenticación refleja la API HTTP: cuando se requieren tokens, pasa el token como parámetro de consulta, porque los navegadores no pueden fijar cabeceras en un WebSocket:

```
ws://localhost:4000/socket/websocket?token=pepe_your_token_here
```

Si tu API está abierta, quita el parámetro `token`.

### El protocolo de tramas

El socket habla un protocolo de tramas JSON simple. Cada mensaje, en ambas direcciones, es un arreglo JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` y `ref` son cadenas que eliges para correlacionar respuestas con peticiones. `topic` nombra con qué estás hablando. El ciclo de vida es: unirte a un tópico, enviar prompts, opcionalmente reiniciar, y enviar un latido cada 30 segundos aproximadamente para mantener la conexión viva.

```json
// 1. Join a topic. "agent:<name>", or "agent:default" for the default agent.
//    The join payload may carry a stable session to keep the same
//    notification channel across reconnects.
["1", "1", "agent:default", "phx_join", {}]

// 2. Send a prompt. The reply streams back as separate frames.
["1", "2", "agent:default", "prompt", { "text": "hola" }]

// 3. Reinicia el historial de conversación de este tema.
["1", "3", "agent:default", "reset", {}]

// 4. Heartbeat, every ~30s, so the connection is not dropped.
[null, "h", "phoenix", "heartbeat", {}]
```

Unirse a `agent:<name>` selecciona y autoriza ese agente contra el ámbito de tu token, exactamente como el campo `model` por HTTP. El ámbito se aplica en el `join`, así que un tópico que tu token no permite se rechaza ahí mismo. `agent:default` resuelve al agente predeterminado del ámbito de tu token. Un nombre simple se cualifica dentro de la empresa de tu token, así que un token con ámbito `acme` que se une a `agent:sales` llega a `acme/sales`, y un token de empresa que intente unirse al agente de otra empresa se rechaza. Pasa `{"session": "some-stable-id"}` en el payload de unión para mantener el mismo canal de vigilancia/notificación entre reconexiones; de lo contrario se usa un id nuevo por conexión. Pasa también `{"lang": "pt-BR"}` y eso empuja la primera respuesta del agente hacia ese idioma (un aviso de sistema único en el primer turno de la sesión), así es como el atributo `data-lang` del [widget incrustable](../widget/) llega al agente.

### Eventos

**Envías** dos eventos entrantes:

* `prompt` con `{ "text": "..." }`: envía un mensaje y transmite la respuesta.
* `reset` con `{}`: limpia el historial de la conversación.

**Recibes** estos eventos salientes, cada uno llegando como una trama cuyo payload se muestra:

* `delta` `{ "text": "..." }`: un fragmento en streaming de la respuesta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: el agente está invocando una herramienta.
* `tool_result` `{ "name": "...", "output": "..." }`: la salida de esa herramienta.
* `done` `{ "content": "..." }`: la respuesta final; el turno está completo.
* `session_ended` `{}`: el agente llamó a `end_session`. Su respuesta de cierre ya
  llegó por el `done` anterior, y el *siguiente* prompt empieza con contexto nuevo.
* `watch` `{ "text": "..." }`: una vigilancia creada desde esta conexión se ha disparado.
* `error` `{ "reason": "..." }`: algo salió mal en este turno.

### JavaScript (el cliente phoenix)

En JavaScript la forma ergonómica de consumir esto es el paquete npm `phoenix`, que se encarga de las tramas, los refs y los latidos por ti:

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

channel.push("prompt", { text: "¿Qué archivos hay en el directorio actual?" });
```

### Tramas crudas (cualquier lenguaje)

Sin el paquete `phoenix`, habla el protocolo de tramas directamente sobre cualquier cliente WebSocket. Este ejemplo en Python se une, envía un prompt, imprime los deltas en streaming y se detiene cuando llega `done`. Fíjate en el latido que debes enviar periódicamente en una conexión de larga duración.

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

Envía una trama de latido, `[null, "h", "phoenix", "heartbeat", {}]`, aproximadamente cada 30 segundos para mantener abierta una conexión de larga duración.
