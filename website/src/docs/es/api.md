---
title: API HTTP
description: Llama a Pepe mediante la API Chat Completions compatible con OpenAI.
---

Pepe sirve tus agentes a través de una API HTTP que habla el protocolo Chat Completions de OpenAI. Cualquier herramienta o SDK capaz de comunicarse con OpenAI puede comunicarse con Pepe sin cambiar una línea de código: apunta su `base_url` a tu servidor Pepe y usa el nombre de un agente donde normalmente pondrías un id de modelo. También puedes llamar el endpoint con peticiones HTTP directas desde tus propios proyectos, sitios, backends, jobs o integraciones; usar un SDK de LLM es cómodo, pero no obligatorio. También hay un WebSocket para streaming en vivo, token a token, con visibilidad de las llamadas a herramientas.

Las dos superficies cubren dos necesidades. La API HTTP es la opción por defecto para el trabajo de petición/respuesta y de servidor a servidor. El WebSocket es para interfaces interactivas donde quieres renderizar las llamadas a herramientas y el texto en streaming a medida que ocurren.

## Una primera petición

Arranca el servidor y luego envía una chat completion. Esto funciona de fábrica sin autenticación (consulta [Autenticación](../auth/#autenticación-y-tokens) para cerrarlo con llave):

```bash
pepe serve --port 4000
```

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

**Elixir (usando Req)**

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

La respuesta es un objeto estándar de chat completion de OpenAI:

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

`pepe serve` corre en primer plano - para un despliegue de verdad, consulta [Panel](../dashboard/#mantenerlo-en-marcha) para instalarlo como servicio persistente en segundo plano.

## Endpoints

Hay dos:

```http
POST /v1/chat/completions   # non-streaming or streaming (Server-Sent Events)
GET  /v1/models             # lists your agents (and, in the open/root scope, raw model connections)
```

Ambos viven bajo `/v1`, así que un cliente configurado con `base_url = http://HOST:PORT/v1` los encuentra exactamente donde un cliente de OpenAI espera encontrarlos.

## El campo "model" selecciona un agente

Esta es la idea que hace que todo lo demás encaje. El campo `model` de una petición de chat no nombra un modelo de lenguaje crudo. Nombra un **agente** de Pepe. Cuando envías `"model": "assistant"`, Pepe ejecuta el agente llamado `assistant`, con el prompt de sistema de ese agente y su propio conjunto de herramientas. El agente ejecuta el bucle completo de llamadas a herramientas de forma interna (llama al modelo, ejecuta las llamadas a herramientas, devuelve los resultados, repite) y retorna una única respuesta final con la forma habitual de una completion.

La resolución del campo `model` ocurre en este orden:

1. Si el nombre coincide con un agente, ese agente se ejecuta.
2. Si ningún agente coincide pero el nombre coincide con una conexión de modelo pura, Pepe la envuelve en un agente mínimo de paso directo (sin herramientas, un solo turno) y llama a ese modelo directamente. Esta alternativa solo está disponible en el ámbito abierto o raíz (consulta [Ámbitos de token](../auth/#ámbitos-de-token)).
3. Si ninguno coincide, se ejecuta el agente por defecto.

<div class="note"><strong>Conclusión práctica.</strong> El conjunto de "modelos" que un cliente puede elegir es tu conjunto de agentes. Dale a un agente un nombre descriptivo, conecta sus herramientas una vez y cada cliente compatible con OpenAI lo verá como un modelo seleccionable.</div>

## Chat completions

### Sin streaming

Envía `messages` con la forma de OpenAI. Puedes incluir un mensaje `system`; si lo omites, se usa automáticamente el prompt de sistema propio del agente.

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

Pon `"stream": true` para recibir la respuesta a medida que se genera. El formato en el cable es idéntico al streaming de OpenAI: una secuencia de líneas `data:`, cada una con un objeto `chat.completion.chunk`, terminada por `data: [DONE]`.

```bash
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "stream": true,
    "messages": [{"role": "user", "content": "Count to five slowly."}]
  }'
```

Cada fragmento se ve así, con el texto incremental en `choices[0].delta.content`:

```json
{
  "id": "chatcmpl-Yb3n...",
  "object": "chat.completion.chunk",
  "created": 1751800000,
  "model": "assistant",
  "choices": [{ "index": 0, "delta": { "content": "one " }, "finish_reason": null }]
}
```

El último fragmento lleva un delta vacío y `"finish_reason": "stop"`, seguido de la línea centinela `data: [DONE]`. Como esto coincide con OpenAI byte por byte, cualquier cliente de streaming de OpenAI lo analiza sin cambios.

## Errores

Los errores vuelven con la forma de error de OpenAI (un objeto `error` de nivel superior con un `message`), de modo que el manejo de errores existente funciona. Los códigos de estado:

* `401` cuando se requiere un token pero falta o no es válido.
* `403` cuando nombras un agente que existe pero está fuera del ámbito de tu token.
* `400` cuando el campo `model` no resuelve a ningún agente ni a ningún modelo.
* `502` cuando el agente o una sesión con estado falla durante la ejecución.

El `401` de la capa de autenticación lleva el código `invalid_api_key` de OpenAI:

```json
{
  "error": {
    "message": "invalid or missing API token",
    "type": "invalid_request_error",
    "code": "invalid_api_key"
  }
}
```

Los errores de ámbito y resolución (`400`, `403`, `502`) usan un tipo `pepe_error`:

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

Los agentes se etiquetan como `pepe:agent`. En el ámbito abierto o raíz, también aparecen las conexiones de modelo puras, etiquetadas como `pepe:model`. Como es una lista de modelos estándar, las herramientas de OpenAI que ofrecen un selector de modelo lo llenan con tus agentes.
