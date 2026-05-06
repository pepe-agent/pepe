---
title: Sesiones
description: Usa memoria de conversación del lado del servidor por HTTP y WebSocket.
---

## Sesiones: con estado vs sin estado

Por defecto la API es **sin estado**: cada petición debe llevar el historial completo de mensajes, exactamente como en OpenAI. Envías todo, Pepe responde, no se recuerda nada.

Pepe también ofrece un modo **con estado** que la mayoría de los servidores de OpenAI no tienen. Adjunta un id de sesión y el servidor mantiene la conversación por ti. En cada llamada posterior envías solo el mensaje más nuevo del usuario; Pepe lo añade al historial almacenado, ejecuta el agente y recuerda el resultado. Esto es cómodo para interfaces de chat y bots de mensajería donde no quieres enviar toda la transcripción cada vez.

## CLI vs API

`pepe run` siempre es una ejecución suelta: no acepta `session_id` y no recuerda el
comando anterior. Para mantener contexto en la terminal, usa la consola:

```bash
pepe chat assistant --session mi-sesion
```

La API HTTP toma la clave de sesión de **dos campos, y se combinan**.

- **`user`** identifica *quién* habla. Es el campo estándar de OpenAI, así que cualquier SDK oficial obtiene memoria en el servidor sin salirse del formato estándar. Es el que deberías usar.
- **`session_id`**, en el cuerpo JSON o una cabecera `x-session-id`, identifica *qué conversación* suya. Úsalo cuando una persona pueda tener varios hilos separados.

Cómo se combinan:

| Enviado | Clave de sesión |
| --- | --- |
| solo `user` | `user` |
| solo `session_id` | `session_id` |
| ambos | `user:session_id` (hilos independientes por persona) |
| ambos, mismo valor | se reduce a uno |
| ninguno (o vacío) | sin estado |

Así, en WhatsApp puedes pasar `user` = el número de teléfono y `session_id` = un id de hilo, y cada hilo de cada contacto es su propia conversación, aislada del resto.

```bash
# Turno 1: solo hace falta el mensaje nuevo; el servidor guarda el historial.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "Mi nombre es Ada."}]
  }'

# Turno 2: mismo id de sesión, solo la pregunta nueva. El agente recuerda "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "¿Cómo me llamo?"}]
  }'
```

En el modo con estado la respuesta incluye el `session_id` que usaste, para que puedas devolverlo en la siguiente llamada. Las sesiones con estado también funcionan con streaming; solo añade `"stream": true`.

### Recuperarse de un reinicio

Si Pepe se cae a mitad de un turno (un despliegue, un fallo) mientras la persistencia de sesiones está activa, la conversación interrumpida no se pierde sin más. En el siguiente arranque, Pepe detecta cualquier sesión cuyo último turno no terminó, la reproduce como un seguimiento interno y entrega la respuesta a donde estaba ocurriendo la conversación (Telegram, el panel, el canal que sea), así que un mensaje interrumpido igual recibe respuesta en vez de desaparecer en silencio. Esto solo aplica a sesiones persistidas (`serve`/`gateway`), no a llamadas sueltas de `pepe run`.

<div class="note"><strong>Aislamiento entre empresas.</strong> Las claves de sesión están internamente delimitadas por empresa. El mismo id de sesión usado bajo dos tokens distintos (dos empresas distintas) nunca llega a la misma conversación, de modo que una empresa nunca puede leer la sesión de otra.</div>

Para volver a modo sin estado, simplemente omite las tres fuentes de id y envía tú mismo el arreglo completo de `messages`. Ese es el comportamiento normal de OpenAI.
