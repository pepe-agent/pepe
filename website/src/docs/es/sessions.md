---
title: Sesiones
description: Memoria de conversación del lado del servidor, disponible por HTTP y por WebSocket.
---

## Sesiones: con estado o sin estado

Por defecto, la API es **sin estado**: cada solicitud tiene que traer el historial
completo de mensajes, tal cual funciona OpenAI. Envías todo, Pepe responde, y no queda
nada guardado.

Pepe también ofrece un modo **con estado** que la mayoría de los servidores compatibles
con OpenAI no tiene. Basta con adjuntar un id de sesión para que el propio servidor
mantenga la conversación por ti. En cada llamada siguiente solo envías el mensaje nuevo
del usuario; Pepe lo agrega al historial que ya tenía guardado, corre el agente, y
recuerda el resultado. Es justo lo que conviene para interfaces de chat o bots de
mensajería, donde no tiene sentido reenviar toda la transcripción cada vez.

## CLI frente a API

`pepe run` siempre es de una sola vez: no acepta `session_id` ni recuerda el comando
anterior. Si necesitas mantener contexto en la terminal, usa la consola interactiva:

```bash
pepe chat assistant --session mi-sesion
```

La API HTTP arma la clave de sesión a partir de **dos campos que se combinan entre sí**.

- **`user`** identifica *quién* está hablando. Es el campo estándar de OpenAI, así que
  cualquier SDK oficial obtiene memoria del lado del servidor sin salirse del formato de
  siempre. Es el que conviene usar como primera opción.
- **`session_id`**, ya sea en el cuerpo JSON o en un encabezado `x-session-id`, identifica
  *cuál* de las conversaciones de esa persona. Úsalo cuando alguien puede tener varios
  hilos separados en paralelo.

Así se combinan:

| Se envía | Clave de sesión resultante |
| --- | --- |
| solo `user` | `user` |
| solo `session_id` | `session_id` |
| ambos | `user:session_id` (hilos independientes por persona) |
| ambos, con el mismo valor | se reducen a uno solo |
| ninguno (o vacíos) | sin estado |

Por eso en WhatsApp puedes pasar `user` como el número de teléfono y `session_id` como un
id de hilo, y cada hilo de cada contacto queda como su propia conversación, sin mezclarse
con las demás.

```bash
# Turno 1: solo hace falta el mensaje nuevo; el servidor ya guarda el historial.
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

En modo con estado, la respuesta trae de vuelta el `session_id` que usaste, así que puedes
reenviarlo tal cual en la siguiente llamada. Las sesiones con estado también funcionan con
streaming; solo agrega `"stream": true`.

### Recuperarse de un reinicio

Si Pepe se cae a mitad de un turno (por un despliegue, por un fallo) mientras la
persistencia de sesiones está activa, la conversación interrumpida no queda simplemente
perdida. Al arrancar de nuevo, Pepe detecta cualquier sesión cuyo último turno haya
quedado sin terminar, lo vuelve a ejecutar como si fuera un seguimiento interno, y entrega
la respuesta justo donde estaba ocurriendo esa conversación, sea Telegram, el panel o
cualquier otro canal. El mensaje interrumpido termina recibiendo su respuesta en vez de
desaparecer sin dejar rastro. Esto aplica solo a sesiones persistidas (`serve`/`gateway`),
no a llamadas sueltas de `pepe run`.

<div class="note"><strong>Aislamiento entre proyectos.</strong> Las claves de sesión quedan internamente delimitadas por proyecto. El mismo id de sesión usado bajo dos tokens distintos, es decir dos proyectos distintos, jamás apunta a la misma conversación: un proyecto nunca puede leer la sesión de otro.</div>

Para volver al modo sin estado, basta con omitir las tres fuentes de id y enviar tú mismo
el arreglo completo de `messages`. Ese es el comportamiento habitual de OpenAI.
