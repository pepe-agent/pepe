---
title: API HTTP
description: Llama a Pepe mediante la API Chat Completions compatible con OpenAI.
---

Pepe expone tus agentes a través de una API HTTP que habla el protocolo Chat
Completions de OpenAI. Cualquier herramienta o SDK capaz de hablar con OpenAI
puede hablar con Pepe sin cambiar una sola línea de código: apunta su
`base_url` a tu servidor Pepe y usa el nombre de un agente donde normalmente
pondrías un id de modelo. También puedes llamar al endpoint con peticiones HTTP
directas desde tus propios proyectos, sitios, backends, jobs o integraciones;
un SDK de LLM es cómodo, pero no hace falta. También hay un WebSocket para
streaming en vivo, token a token, con visibilidad completa de las llamadas a
herramientas.

Las dos superficies cubren necesidades distintas. La API HTTP es la opción por
defecto para trabajo de petición y respuesta, o de servidor a servidor. El
WebSocket sirve para interfaces interactivas donde quieres mostrar las llamadas
a herramientas y el texto en streaming a medida que van ocurriendo.

## Una primera llamada

Arranca el servidor y luego manda una chat completion. Esto funciona de fábrica
sin ninguna autenticación (consulta [Autenticación](../auth/#autenticación-y-tokens)
para cerrarlo con llave):

```bash
pepe serve --port 4000
```

¿Estás corriendo Pepe desde el código fuente en vez del binario instalado?
`PHX_SERVER=true mix phx.server` sirve exactamente el mismo endpoint.

**curl**

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "hola"}]
  }'
```

**JavaScript**

```javascript
const response = await fetch("http://localhost:4000/v1/chat/completions", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    model: "assistant",
    messages: [{ role: "user", content: "hola" }]
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
        "messages": [{"role": "user", "content": "hola"}],
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
        "messages" => [["role" => "user", "content" => "hola"]],
    ]),
]);

$data = json_decode(curl_exec($ch), true);
echo $data["choices"][0]["message"]["content"];
```

**Elixir (con Req)**

```elixir
Req.post!("http://localhost:4000/v1/chat/completions",
  json: %{
    model: "assistant",
    messages: [%{role: "user", content: "hola"}]
  }
).body["choices"]
|> hd()
|> get_in(["message", "content"])
|> IO.puts()
```

La respuesta es un objeto de chat completion estándar de OpenAI:

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

`pepe serve` corre en primer plano. Para un despliegue real, consulta
[Panel](../dashboard/#dejarlo-corriendo-de-forma-permanente) para instalarlo como servicio
persistente en segundo plano.

## Endpoints

Son dos:

```http
POST /v1/chat/completions   # sin streaming, o con streaming (Server-Sent Events)
GET  /v1/models             # lista tus agentes (y, en el ámbito abierto o de proyecto por defecto, las conexiones de modelo puras)
```

Los dos viven bajo `/v1`, así que un cliente configurado con
`base_url = http://HOST:PORT/v1` los encuentra exactamente donde un cliente de
OpenAI espera encontrarlos.

## El campo "model" elige un agente

Esta es la idea que hace que todo lo demás encaje. El campo `model` de una
petición de chat no nombra un modelo de lenguaje puro; nombra un **agente** de
Pepe. Cuando envías `"model": "assistant"`, Pepe corre el agente llamado
`assistant`, con el system prompt y el conjunto de herramientas propios de ese
agente. El agente ejecuta internamente el ciclo completo de llamadas a
herramientas (llama al modelo, corre las llamadas a herramientas, devuelve los
resultados, repite) y entrega una única respuesta final con la forma habitual
de una completion.

Pepe resuelve el campo `model` en este orden:

1. Si el nombre coincide con un agente, corre ese agente.
2. Si ningún agente coincide pero el nombre sí coincide con una conexión de
   modelo pura, Pepe la envuelve en un agente mínimo de paso directo (sin
   herramientas, un solo turno) y llama a ese modelo directamente. Esta salida
   solo está disponible en el ámbito abierto o en el del proyecto por defecto
   (consulta [Ámbitos de token](../auth/#ámbitos-de-token)).
3. Si no coincide ninguno de los dos, corre el agente por defecto.

<div class="note"><strong>En la práctica.</strong> El conjunto de "modelos"
entre los que puede elegir un cliente es tu conjunto de agentes. Dale a un
agente un nombre descriptivo, conecta sus herramientas una sola vez, y
cualquier cliente compatible con OpenAI lo verá como un modelo más para
seleccionar.</div>

## Chat completions

### Sin streaming

Manda `messages` con el formato de OpenAI. Puedes incluir un mensaje `system`;
si lo omites, se usa automáticamente el system prompt propio del agente.

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

### Con streaming (Server-Sent Events)

Pon `"stream": true` para recibir la respuesta a medida que se va generando. El
formato en el cable es idéntico al streaming de OpenAI: una secuencia de
líneas `data:`, cada una con un objeto `chat.completion.chunk`, terminada con
`data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento tiene esta forma, con el texto incremental en
`choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

El último fragmento trae un delta vacío y `"finish_reason": "stop"`, seguido de
la línea centinela `data: [DONE]`. Como esto coincide con OpenAI byte por
byte, cualquier cliente de streaming de OpenAI lo procesa sin ningún cambio.

## Sesiones con estado

Por defecto el endpoint no guarda estado: envías el arreglo `messages`
completo en cada llamada, igual que harías con OpenAI. Si en cambio pasas un
id de sesión, el servidor guarda toda la conversación por ti, así que cada
llamada posterior solo necesita llevar el mensaje nuevo del usuario.

Dos campos alimentan la clave de sesión, y se combinan entre sí:

* `"user": "abc"` indica **quién** habla. Es el campo estándar de OpenAI, así
  que un SDK normal de OpenAI mantiene una conversación sin necesitar ningún
  campo propio de Pepe.
* `"session_id": "xyz"`, en el cuerpo JSON o como cabecera `X-Session-Id`,
  indica **cuál** de sus conversaciones es.

| Se envía | Clave de sesión |
| --- | --- |
| solo `user` | `abc` |
| solo `session_id` | `xyz` |
| ambos | `abc:xyz` (hilos independientes por persona) |
| ambos, con el mismo valor | se reduce a uno solo |
| ninguno, o en blanco | sin estado |

Así, en WhatsApp puedes pasar `user` como el número de teléfono y
`session_id` como un id de hilo, y cada hilo de cada contacto se convierte en
su propia conversación. Una cadena vacía (`""`) en cualquiera de los dos campos
se trata como sin estado.

```bash
# Turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"mi nombre es John Doe"}]}'

# Turno 2, mismo "user". El servidor recuerda el turno 1.
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"¿cuál es mi nombre?"}]}'
```

Cada sesión es su propio proceso supervisado, identificado como `api:<id>`. El
streaming también funciona con sesiones. El WebSocket y Telegram guardan
estado por diseño (por conexión y por id de chat, respectivamente), así que no
necesitan nada de esto. Consulta [Sesiones](../sessions/) para el panorama
completo, incluido qué pasa con un turno sin terminar cuando Pepe se reinicia.

## Errores

Los errores vuelven con la forma habitual de OpenAI (un objeto `error` de
nivel superior con un `message`), así que el manejo de errores que ya tengas
sigue funcionando. Los códigos de estado son:

* `401` cuando se requiere un token y falta, o no es válido.
* `403` cuando nombras un agente que existe pero cae fuera del ámbito de tu
  token.
* `400` cuando el campo `model` no resuelve ni a un agente ni a un modelo.
* `502` cuando el agente, o una sesión con estado, falla mientras corre.

El `401` de la capa de autenticación lleva el código `invalid_api_key` de
OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Los errores de ámbito y de resolución (`400`, `403`, `502`) usan el tipo
`pepe_error`:

```json
{
  "error": {
    "message": "agent not accessible with this token",
    "type": "pepe_error"
  }
}
```

## Comprobación de estado

`GET /health` (también `/healthz`) es una sonda de disponibilidad sin
autenticación, pensada para balanceadores de carga y monitores de uptime. Es
deliberadamente mínima y nunca lista agentes ni modelos, así que no filtra
ningún dato de ningún cliente:

```bash
curl http://localhost:4000/health
```

```json
{ "status": "ok", "service": "pepe", "ready": true }
```

`ready` pasa a `true` en cuanto existen al menos una conexión de modelo y un
agente, es decir, en cuanto el servicio puede realmente responder algo. Para
descubrir qué agentes y modelos puede alcanzar quien llama, usa
`GET /v1/models`, que sí está autenticado y acotado por ámbito.

## Listar modelos

`GET /v1/models` devuelve los agentes (y, en el ámbito abierto o del proyecto
por defecto, las conexiones de modelo puras) a los que puede llegar quien
hace la llamada, con el formato de modelos de OpenAI. Esta es la forma
correcta y acotada, por proyecto, de descubrir qué hay disponible: con un
token de proyecto solo se listan los agentes de ese proyecto, nunca los de
otro cliente, y nunca las conexiones de modelo puras.

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

Los agentes se etiquetan como `pepe:agent`. En el ámbito abierto o del
proyecto por defecto, también aparecen las conexiones de modelo puras,
etiquetadas como `pepe:model`. Como es una lista de modelos estándar,
cualquier herramienta de OpenAI que ofrezca un selector de modelo la llena con
tus agentes.
