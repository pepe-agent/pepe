---
title: Tareas programadas
description: Ejecuta agentes en horarios cron recurrentes.
---

## Tareas recurrentes

Una tarea es un prompt autocontenido, un horario, una zona horaria y un lugar donde entregar el resultado. Cuando se dispara, Pepe ejecuta el agente sobre ese prompt en una **sesión nueva y sin historial de chat**. No se arrastra nada de ninguna conversación anterior, así que el prompt tiene que decir todo lo que la ejecución necesita (qué hacer, qué datos mirar, la ventana de tiempo).

### Crear una tarea desde la CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Resume las líneas de log de error de las últimas 24 horas y lista los 3 problemas principales." \
  --schedule "0 9 * * 1-5" \
  --timezone "America/Sao_Paulo" \
  --deliver "telegram:123456789"
```

Solo `--name`, `--prompt` y `--schedule` son obligatorios. El resto tiene valores por defecto razonables:

| Opción | Qué hace | Por defecto |
| --- | --- | --- |
| `--agent` | Qué agente ejecuta el prompt | Tu agente por defecto |
| `--timezone` | Zona horaria IANA en la que se lee el horario | La configurada por defecto (ver abajo) |
| `--model` | Ejecuta esta tarea con una conexión de modelo concreta | El modelo propio del agente |
| `--deliver` | A dónde va el resultado | `none` (se registra, no se envía a ningún lado) |

El conjunto completo de comandos:

```bash
pepe cron list                 # todas las tareas, con su próxima ejecución
pepe cron add ...              # crea una tarea (ver arriba)
pepe cron run morning-brief    # fuerza una ejecución ahora e imprime el resultado
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # historial reciente de ejecuciones
```

Cada tarea recibe un id legible derivado de su nombre (`morning-brief`). Si ese id ya está ocupado, Pepe le añade un número (`morning-brief-2`).

### Hazlo en el panel

Ejecuta `pepe serve` y abre la página **Scheduled**. Lista cada tarea con su próxima hora de ejecución, y te da las mismas acciones como botones: crear una tarea nueva con un formulario, forzar una ejecución ahora, activar o desactivar, editar, eliminar y abrir el historial de una tarea en el mismo lugar. Cuando escribes el horario de una tarea, el panel puede convertir una frase sencilla como "cada día laborable a las 9:30" en la expresión cron correspondiente por ti, usando un modelo configurado, y valida el resultado antes de guardarlo.

### Expresiones de horario y zonas horarias

El horario es una expresión cron estándar de 5 campos: `minuto hora día-del-mes mes día-de-la-semana`.

```
0 9 * * 1-5     # 09:00, lunes a viernes
*/15 * * * *    # cada 15 minutos
0 0 1 * *       # medianoche del día 1 de cada mes
30 8 * * *      # 08:30 todos los días
```

Una tarea lleva su propia **zona horaria con nombre**, no un desfase fijo respecto a UTC. Esto importa porque "las 9am locales" se desplazan respecto a UTC dos veces al año con el horario de verano. Pepe guarda la expresión más un nombre de zona como `America/Sao_Paulo` o `Europe/Berlin`, y evalúa el horario en esa zona. En torno a un cambio de horario de verano hace lo sensato: salta hacia adelante en el hueco de primavera y elige el lado tardío del solapamiento de otoño, de modo que un trabajo nunca se dispara dos veces ni desaparece en silencio.

Define tu zona por defecto una vez durante `pepe setup`. Las tareas que no nombran su propia zona la usan. Si no hay nada configurado, el valor de reserva es UTC.

<div class="note"><strong>Describe el horario con palabras.</strong> Una expresión cron es fácil de escribir mal a mano. Tanto el formulario del panel como un agente por chat pueden convertir una frase como "cada día laborable a las 9:30" en la expresión correspondiente por ti. Cada expresión generada se valida antes de guardarla, así que nunca se almacena una inválida.</div>

### A dónde va el resultado

El destino de `deliver` decide qué pasa con la salida de una ejecución:

- `telegram:<chat_id>` lo envía a ese chat de Telegram. El mensaje lleva como prefijo el nombre de la tarea, para que un chat que recibe varias tareas pueda distinguirlas.
- `none` no lo envía a ningún lado. La ejecución igual corre y queda registrada en el historial. Bueno para tareas cuyo único fin es un efecto secundario (escribir un archivo, llamar a una herramienta).
- Cualquier otra cosa (incluido `log`) escribe la salida en el log de la aplicación.

Sea cual sea el destino, cada ejecución se añade al archivo de historial propio de esa tarea, así que siempre puedes releer lo que pasó.

### El temporizador por minuto y la recuperación

El programador hace un tick cada 30 segundos (a propósito por debajo del minuto, para que una pequeña deriva del reloj nunca le haga perder un minuto). En cada tick mira todas las tareas activas y dispara las que coinciden con el minuto actual en la zona horaria de esa tarea. Un guardián por tarea asegura que un trabajo se dispare **como mucho una vez por minuto** aunque el tick sea más rápido que eso.

Si el proceso estaba caído en el momento en que una tarea debía dispararse, Pepe hace una **recuperación** acotada al reiniciar. Cuando vuelve y nota que pasó una ranura programada sin ejecución, dispara ese trabajo una vez, siempre que aún esté dentro de una ventana de gracia (la mitad del periodo del trabajo, acotada entre 2 minutos y 2 horas). La recuperación está anclada a la ranura perdida, así que un solo reinicio nunca dispara dos veces. Un trabajo que estuvo caído mucho más tiempo que su ventana de gracia simplemente se retoma en su próxima ranura normal, en lugar de repetir una vieja.

### Historial de ejecuciones

Cada disparo, ya sea del temporizador, de un `pepe cron run` forzado, de un botón del panel o de un chat, añade una línea al archivo de historial de esa tarea (`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada línea registra la marca de tiempo, la fuente, si tuvo éxito y la salida (recortada).

```bash
pepe cron logs morning-brief
```

```
✦ Runs of morning-brief

✅ 2026-07-06 09:00 · scheduler
   3 issues overnight. Top: DB connection pool exhausted (x42), ...

⚠️ 2026-07-05 09:00 · scheduler
   error: :timeout
```

El campo `source` de cada línea es uno de `scheduler` (lo disparó el temporizador), `manual` (lo forzaste desde la CLI o el panel) o `agent` (lo forzó un chat).

### Hazlo por chat

Un agente puede crear y gestionar sus propias tareas programadas durante una conversación, en el chat de la CLI o en cualquier canal conectado, si tiene la herramienta `schedule_task` en su conjunto. Pídelo en lenguaje natural:

> Cada día laborable a las 8:30 de mi hora, revisa la página de estado y avísame aquí si algo está degradado.

El agente conoce la hora local actual (su system prompt está anclado con ella), así que "mañana a las 8:30" se resuelve a la ranura correcta en vez de derivar a UTC. Escribe por ti el prompt completo y autocontenido, elige la expresión cron y, por defecto, entrega el resultado de vuelta al mismo chat desde el que preguntaste.

La herramienta `schedule_task` admite las mismas acciones que la CLI: `create`, `list`, `run` (forzar ahora para previsualizar), `enable`, `disable`, `remove` e `history`.

#### La doble aprobación

Crear trabajo programado desde el chat está deliberadamente protegido dos veces, porque una tarea corre sola más tarde:

1. **La herramienta tiene que estar concedida al agente.** Un agente solo puede programar algo si `schedule_task` está en su lista de permitidos. Los agentes sin ella simplemente no pueden.
2. **Cada creación igual te pregunta.** `schedule_task` es una herramienta con control, así que a menos que se haya preaprobado, el runtime te pide autorizar la llamada concreta antes de que surta efecto. Cada superficie muestra ese aviso a su manera nativa (botones en línea en Telegram, un menú con las flechas del teclado en la terminal). Puedes responder solo por esta vez, por el resto de la sesión, siempre (recordado en el agente) o denegar.

Así una tarea nunca aparece a tus espaldas: la capacidad es opcional, y cada tarea concreta también lo es.
