---
title: API HTTP y WebSocket
description: Sirve tus agentes a traves de una API HTTP compatible con OpenAI y un WebSocket con streaming. Apunta cualquier SDK de OpenAI a Pepe y trata cada agente como un modelo.
---

Pepe sirve tus agentes a traves de una API HTTP que habla el protocolo Chat Completions de OpenAI. Cualquier herramienta o SDK capaz de comunicarse con OpenAI puede comunicarse con Pepe sin cambiar una linea de codigo: apunta su `base_url` a tu servidor Pepe y usa el nombre de un agente donde normalmente pondrias un id de modelo. Tambien hay un WebSocket para streaming en vivo, token a token, con visibilidad de las llamadas a herramientas.

Las dos superficies cubren dos necesidades. La API HTTP es la opcion por defecto para el trabajo de peticion/respuesta y de servidor a servidor. El WebSocket es para interfaces interactivas donde quieres renderizar las llamadas a herramientas y el texto en streaming a medida que ocurren.

## Una primera llamada

Arranca el servidor y luego envia una chat completion. Esto funciona de fabrica sin autenticacion (consulta [Autenticacion](#autenticacion-y-tokens) para cerrarlo con llave):

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

La respuesta es un objeto estandar de chat completion de OpenAI:

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

Hay dos:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Ambos viven bajo `/v1`, asi que un cliente configurado con `base_url = http://HOST:PORT/v1` los encuentra exactamente donde un cliente de OpenAI espera encontrarlos.

## El campo "model" selecciona un agente

Esta es la idea que hace que todo lo demas encaje. El campo `model` de una peticion de chat no nombra un modelo de lenguaje crudo. Nombra un **agente** de Pepe. Cuando envias `"model": "assistant"`, Pepe ejecuta el agente llamado `assistant`, con el prompt de sistema de ese agente y su propio conjunto de herramientas. El agente ejecuta el bucle completo de llamadas a herramientas de forma interna (llama al modelo, ejecuta las llamadas a herramientas, devuelve los resultados, repite) y retorna una unica respuesta final con la forma habitual de una completion.

La resolucion del campo `model` ocurre en este orden:

1. Si el nombre coincide con un agente, ese agente se ejecuta.
2. Si ningun agente coincide pero el nombre coincide con una conexion de modelo pura, Pepe la envuelve en un agente minimo de paso directo (sin herramientas, un solo turno) y llama a ese modelo directamente. Esta alternativa solo esta disponible en el ambito abierto o raiz (consulta [Ambitos de token](#ambitos-de-token)).
3. Si ninguno coincide, se ejecuta el agente por defecto.

<div class="note"><strong>Conclusion practica.</strong> El conjunto de "modelos" que un cliente puede elegir es tu conjunto de agentes. Dale a un agente un nombre descriptivo, conecta sus herramientas una vez y cada cliente compatible con OpenAI lo vera como un modelo seleccionable.</div>

## Chat completions

### Sin streaming

Envia `messages` con la forma de OpenAI. Puedes incluir un mensaje `system`; si lo omites, se usa automaticamente el prompt de sistema propio del agente.

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

Pon `"stream": true` para recibir la respuesta a medida que se genera. El formato en el cable es identico al streaming de OpenAI: una secuencia de lineas `data:`, cada una con un objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento se ve asi, con el texto incremental en `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

El ultimo fragmento lleva un delta vacio y `"finish_reason": "stop"`, seguido de la linea centinela `data: [DONE]`. Como esto coincide con OpenAI byte por byte, cualquier cliente de streaming de OpenAI lo analiza sin cambios.

## Sesiones: con estado vs sin estado

Por defecto la API es **sin estado**: cada peticion debe llevar el historial completo de mensajes, exactamente como en OpenAI. Envias todo, Pepe responde, no se recuerda nada.

Pepe tambien ofrece un modo **con estado** que la mayoria de los servidores de OpenAI no tienen. Adjunta un id de sesion y el servidor mantiene la conversacion por ti. En cada llamada posterior envias solo el mensaje mas nuevo del usuario; Pepe lo agrega al historial almacenado, ejecuta el agente y recuerda el resultado. Esto es comodo para interfaces de chat y bots de mensajeria donde no quieres enviar toda la transcripcion cada vez.

Puedes pasar el id de sesion de tres formas. Pepe las revisa en este orden:

1. Un campo `session_id` en el cuerpo JSON.
2. El campo estandar de OpenAI `user` en el cuerpo JSON.
3. Una cabecera HTTP `x-session-id`.

La via de `user` es la interesante: `user` es un campo real en el esquema de chat-completions de OpenAI, asi que puedes reutilizarlo como clave de sesion desde cualquier SDK estandar de OpenAI y obtener memoria del lado del servidor sin salir de la forma estandar.

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

En el modo con estado la respuesta incluye el `session_id` que usaste, para que puedas devolverlo en la siguiente llamada. Las sesiones con estado tambien funcionan con streaming; solo agrega `"stream": true`.

<div class="note"><strong>Aislamiento entre inquilinos.</strong> Las claves de sesion estan internamente delimitadas por empresa. El mismo id de sesion usado bajo dos tokens distintos (dos empresas distintas) nunca llega a la misma conversacion, de modo que un inquilino nunca puede leer la sesion de otro.</div>

Para volver a modo sin estado, simplemente omite las tres fuentes de id y envia tu mismo el arreglo completo de `messages`. Ese es el comportamiento normal de OpenAI.

## Autenticacion y tokens

Con **cero tokens configurados, la API esta abierta**. Este es el valor por defecto para un solo inquilino: ejecutala en tu propia maquina o dentro de una red de confianza y saltate la autenticacion por completo.

Crear el primer token acciona un interruptor. Una vez que existe cualquier token, cada peticion debe presentar uno valido o se rechaza con `401`. No hay estado intermedio; el primer token que acuñas cierra la puerta.

### Acuñar y gestionar tokens

Los tokens se crean desde la CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

Un token es una cadena aleatoria con el prefijo `ctx_`. En el archivo de configuracion solo se guarda su hash SHA-256; el token en bruto se imprime una vez al crearlo y nunca mas. Copialo en ese momento. Si lo pierdes, revocalo y acuña uno nuevo.

### Presentar un token

Envialo de cualquiera de las dos formas en que lo haria un cliente estilo OpenAI:

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

Cualquier SDK de OpenAI envia la forma `Authorization: Bearer` cuando fijas su `api_key`, de modo que la autenticacion no necesita ningun tratamiento especial en el cliente.

### Ambitos de token

Un token lleva un ambito que decide a que agentes puede llegar. De lo mas estrecho a lo mas amplio:

* **Fijado a un agente** (`--agent HANDLE`): siempre ejecuta exactamente ese agente. El campo `model` de la peticion se ignora. Entrega esto a quien solo deba alcanzar un agente especifico.
* **Empresa** (`--company CO`): cualquier agente dentro de esa empresa. Un nombre de `model` puro se cualifica dentro de esa empresa automaticamente, y una peticion por un agente que pertenece a otra empresa se rechaza con `403`.
* **Ninguno**: el ambito raiz (sin empresa). Es sobre lo que opera cada comando cuando no le pones ambito. Puede alcanzar los agentes raiz (los que tienen un nombre puro, sin espacio de nombres) y, de forma unica, recurrir a conexiones de modelo puras por nombre.

`GET /v1/models` respeta el ambito: un token de empresa o de agente ve solo sus propios agentes, nunca los de otro inquilino, y nunca las conexiones de modelo puras.

## Enrutamiento multi-inquilino: dale a la empresa X su propio acceso

Los ambitos son la forma de repartir acceso a la API por inquilino. Para dar a una empresa su propia clave, acuña un token con ambito de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: ctx_9f2a... (copy it now, shown once)
```

Quien posea ese token:

* puede alcanzar por nombre cualquier agente que pertenezca a `acme`;
* puede enviar un nombre de `model` puro y que se resuelva dentro de `acme`;
* se rechaza con `403` si nombra un agente de otra empresa;
* ve solo los agentes de `acme` desde `GET /v1/models`.

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

Para fijar un token a exactamente un agente (el campo `model` se ignora entonces por completo), agrega `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "Acme support widget"
```

## Errores

Los errores vuelven con la forma de error de OpenAI (un objeto `error` de nivel superior con un `message`), de modo que el manejo de errores existente funciona. Los codigos de estado:

* `401` cuando se requiere un token pero falta o no es valido.
* `403` cuando nombras un agente que existe pero esta fuera del ambito de tu token.
* `400` cuando el campo `model` no resuelve a ningun agente ni a ningun modelo.
* `502` cuando el agente o una sesion con estado falla durante la ejecucion.

El `401` de la capa de autenticacion lleva el codigo `invalid_api_key` de OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Los errores de ambito y resolucion (`400`, `403`, `502`) usan un tipo `pepe_error`:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Listar modelos

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

Los agentes se etiquetan como `pepe:agent`. En el ambito abierto o raiz, tambien aparecen las conexiones de modelo puras, etiquetadas como `pepe:model`. Como es una lista de modelos estandar, las herramientas de OpenAI que ofrecen un selector de modelo lo llenan con tus agentes.

## Ejemplos de cliente

Cada ejemplo apunta al servidor local. Donde se muestre un token, quitalo si tu API esta abierta.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hello"}] }'
```

**Node (fetch simple)**

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

**Node (SDK de openai)**

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

**Python (SDK de openai)**

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

**Python (requests simple)**

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

**Elixir (usando Req)**

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

## WebSocket: streaming en vivo

El stream SSE por HTTP de arriba es suficiente para la mayoria del streaming de servidor a servidor, y es mas simple de consumir. Recurre al WebSocket cuando estas construyendo una interfaz interactiva y quieres mas que texto: revela cada llamada a herramienta y cada resultado de herramienta a medida que ocurre, y puede empujar una notificacion de vigilancia disparada de vuelta a la misma conexion.

### Conectar

Conectate en `ws://HOST:PORT/socket/websocket` (usa `wss://` sobre TLS). La autenticacion refleja la API HTTP: cuando se requieren tokens, pasa el token como parametro de consulta, porque los navegadores no pueden fijar cabeceras en un WebSocket:

```
ws://localhost:4000/socket/websocket?token=ctx_your_token_here
```

Si tu API esta abierta, quita el parametro `token`.

### El protocolo de tramas

El socket habla un protocolo de tramas JSON simple. Cada mensaje, en ambas direcciones, es un arreglo JSON de cinco elementos:

```
[join_ref, ref, topic, event, payload]
```

`join_ref` y `ref` son cadenas que eliges para correlacionar respuestas con peticiones. `topic` nombra con que estas hablando. El ciclo de vida es: unirte a un topico, enviar prompts, opcionalmente reiniciar, y enviar un latido cada 30 segundos aproximadamente para mantener la conexion viva.

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

Unirse a `agent:<name>` selecciona y autoriza ese agente contra el ambito de tu token, exactamente como el campo `model` por HTTP. Un topico al que no tienes permiso de unirte se rechaza. Pasa `{"session": "some-stable-id"}` en el payload de union para mantener el mismo canal de vigilancia/notificacion entre reconexiones; de lo contrario se usa un id nuevo por conexion.

### Eventos

**Envias** dos eventos entrantes:

* `prompt` con `{ "text": "..." }`: envia un mensaje y transmite la respuesta.
* `reset` con `{}`: limpia el historial de la conversacion.

**Recibes** estos eventos salientes, cada uno llegando como una trama cuyo payload se muestra:

* `delta` `{ "text": "..." }`: un fragmento en streaming de la respuesta.
* `tool_call` `{ "name": "...", "arguments": {...} }`: el agente esta invocando una herramienta.
* `tool_result` `{ "name": "...", "output": "..." }`: la salida de esa herramienta.
* `done` `{ "content": "..." }`: la respuesta final; el turno esta completo.
* `watch` `{ "text": "..." }`: una vigilancia creada desde esta conexion se ha disparado.
* `error` `{ "reason": "..." }`: algo salio mal en este turno.

### JavaScript (el cliente phoenix)

En JavaScript la forma ergonomica de consumir esto es el paquete npm `phoenix`, que se encarga de las tramas, los refs y los latidos por ti:

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

### Tramas crudas (cualquier lenguaje)

Sin el paquete `phoenix`, habla el protocolo de tramas directamente sobre cualquier cliente WebSocket. Este ejemplo en Python se une, envia un prompt, imprime los deltas en streaming y se detiene cuando llega `done`. Fijate en el latido que debes enviar periodicamente en una conexion de larga duracion.

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

Envia una trama de latido, `[null, "h", "phoenix", "heartbeat", {}]`, aproximadamente cada 30 segundos para mantener abierta una conexion de larga duracion.
