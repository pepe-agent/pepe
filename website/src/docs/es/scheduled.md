---
title: Trabajo programado
description: Ejecuta agentes en un horario recurrente y define vigilancias duraderas del tipo "avisame cuando pase X", impulsadas por un temporizador interno que corre cada medio minuto, sin crontab del sistema y sin base de datos.
---

Pepe puede trabajar mientras no estás. Esto toma dos formas, y cada una resuelve un problema distinto:

1. **Tareas recurrentes** (crons). Una tarea ejecuta un agente en un horario fijo, una y otra vez. "Cada día laborable a las 9am, resume las alertas de la noche." Sigue disparándose hasta que la desactivas o la eliminas.
2. **Vigilancias** ("avisame cuando pase X"). Una vigilancia sigue comprobando una condición y te avisa exactamente una vez cuando se vuelve verdadera. "Avisame cuando termine el despliegue." Y luego se detiene sola.

Ambas corren dentro del propio Pepe. Un pequeño temporizador hace un tick cada 30 segundos y dispara lo que toque. No hay crontab del sistema, ni programador externo, ni base de datos. Todo vive en tu `~/.pepe/config.json`, y el historial de ejecuciones de las tareas se escribe en archivos de log simples. El temporizador solo corre mientras haya una superficie de larga vida en pie, es decir `pepe serve` o un `pepe gateway`. Un comando de un solo uso como `pepe run` nunca lo arranca, así que jamás puede disparar trabajos por su cuenta.

Cada capacidad de esta página se puede manejar de tres formas: la línea de comandos `pepe`, el panel web (ábrelo con `pepe serve`) y por chat, en lenguaje natural, cuando un agente tiene la herramienta de gestión correspondiente.

## Tareas recurrentes

Una tarea es un prompt autocontenido, un horario, una zona horaria y un lugar donde entregar el resultado. Cuando se dispara, Pepe ejecuta el agente sobre ese prompt en una **sesión nueva y sin historial de chat**. No se arrastra nada de ninguna conversación anterior, así que el prompt tiene que decir todo lo que la ejecución necesita (qué hacer, qué datos mirar, la ventana de tiempo).

### Crear una tarea desde la CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Summarize any error-level log lines from the last 24 hours and list the top 3 issues." \
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
pepe cron list                 # every task, with its next run time
pepe cron add ...              # create a task (see above)
pepe cron run morning-brief    # force it now, print the result (a dry run)
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # recent run history
```

Cada tarea recibe un id legible derivado de su nombre (`morning-brief`). Si ese id ya está ocupado, Pepe le añade un número (`morning-brief-2`).

### Hazlo en el panel

Ejecuta `pepe serve` y abre la página **Scheduled**. Lista cada tarea con su próxima hora de ejecución, y te da las mismas acciones como botones: crear una tarea nueva con un formulario, forzar una ejecución ahora, activar o desactivar, editar, eliminar y abrir el historial de una tarea en el mismo lugar. Cuando escribes el horario de una tarea, el panel puede convertir una frase sencilla como "cada día laborable a las 9:30" en la expresión cron correspondiente por ti, usando un modelo configurado, y valida el resultado antes de guardarlo.

### Expresiones de horario y zonas horarias

El horario es una expresión cron estándar de 5 campos: `minuto hora día-del-mes mes día-de-la-semana`.

```
0 9 * * 1-5     # 09:00, Monday through Friday
*/15 * * * *    # every 15 minutes
0 0 1 * *       # midnight on the 1st of each month
30 8 * * *      # 08:30 every day
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

> Cada día laborable a las 8:30 de mi hora, revisa la página de estado y avisame aquí si algo está degradado.

El agente conoce la hora local actual (su system prompt está anclado con ella), así que "mañana a las 8:30" se resuelve a la ranura correcta en vez de derivar a UTC. Escribe por ti el prompt completo y autocontenido, elige la expresión cron y, por defecto, entrega el resultado de vuelta al mismo chat desde el que preguntaste.

La herramienta `schedule_task` admite las mismas acciones que la CLI: `create`, `list`, `run` (forzar ahora para previsualizar), `enable`, `disable`, `remove` e `history`.

#### La doble aprobación

Crear trabajo programado desde el chat está deliberadamente protegido dos veces, porque una tarea corre sola más tarde:

1. **La herramienta tiene que estar concedida al agente.** Un agente solo puede programar algo si `schedule_task` está en su lista de permitidos. Los agentes sin ella simplemente no pueden.
2. **Cada creación igual te pregunta.** `schedule_task` es una herramienta con control, así que a menos que se haya preaprobado, el runtime te pide autorizar la llamada concreta antes de que surta efecto. Cada superficie muestra ese aviso a su manera nativa (botones en línea en Telegram, un menú con las flechas del teclado en la terminal). Puedes responder solo por esta vez, por el resto de la sesión, siempre (recordado en el agente) o denegar.

Así una tarea nunca aparece a tus espaldas: la capacidad es opcional, y cada tarea concreta también lo es.

## Vigilancias

Una vigilancia responde a una pregunta distinta: no "haz esto según el reloj" sino "mantén un ojo en algo y avisame en el momento en que pase". Una vigilancia recomprueba una condición con un temporizador y te notifica **una vez** cuando se vuelve verdadera, y luego se detiene. Es duradera: sobrevive a un reinicio y al cierre de la sesión que la creó, y siempre responde en el canal desde el que se creó.

### Disparadores por sonda y por agente

La parte barata de una vigilancia es el **disparador**, que corre en cada intervalo. Solo cuando el disparador se activa corre la notificación (posiblemente costosa), una vez. Hay dos tipos de disparador:

- Una **sonda** ejecuta un comando de shell y no cuesta tokens por comprobación. El éxito es el código de salida 0 por defecto, o puedes exigir que aparezca una cadena en la salida del comando. Usa una sonda siempre que la condición sea scriptable (una URL está accesible, un trabajo escribió un archivo, un log contiene una línea).
- Un disparador de **agente** le vuelve a preguntar al agente una pregunta de sí/no en cada intervalo, una llamada al modelo por comprobación. Úsalo solo cuando decidir si la condición se cumple requiere verdadero criterio.

Como las comprobaciones de agente cuestan tokens, su intervalo mínimo es más alto: 300 segundos para disparadores de agente, 30 segundos para sondas. El intervalo por defecto es de 120 segundos.

### Qué envía cuando se dispara

Cuando el disparador por fin pasa, una vigilancia entrega un mensaje. Ese mensaje es una **plantilla** fija (un texto que defines por adelantado, sin llamada al modelo) o lo **compone el agente** en el momento del disparo (una llamada al modelo, una vez) para que pueda incluir detalle fresco, como un resumen de lo que realmente pasó.

### Crear una vigilancia desde la CLI

La CLI crea vigilancias por sonda. Las vigilancias juzgadas por un agente se crean desde el chat, donde el modelo ya está en el bucle.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- La descripción (`"api-up"`) se vuelve el id de la vigilancia.
- `--probe` es el comando de shell a sondear. Sin `--contains`, el éxito significa que el comando sale con 0.
- `--contains STR` en su lugar hace que el éxito signifique que `STR` aparece en la salida del comando.
- `--message` es el texto a enviar cuando se dispara. Omítelo para una confirmación por defecto.
- `--every` es el intervalo de sondeo en segundos (mínimo 30).
- `--deliver telegram:<chat>` envía la notificación a ese chat. Omítelo y la notificación va al log de la aplicación.

Gestionar vigilancias:

```bash
pepe watch list                 # all watches, with state and check count
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Hazlo en el panel

Abre la página **Watches** bajo `pepe serve` para ver cada vigilancia con su estado, disparador, intervalo y cuántas comprobaciones ha usado de su presupuesto. Desde ahí puedes pausar, reanudar y cancelar una vigilancia. Las vigilancias nuevas se crean desde la CLI o por chat, donde se configuran el disparador y el destino de entrega.

### Hazlo por chat

Pídelo en lenguaje natural y el agente crea la vigilancia a través de su herramienta `watch`. Igual que `schedule_task`, la herramienta `watch` tiene que estar en el conjunto del agente y pasa por el mismo aviso de permiso en cada creación, así que aplica la misma doble aprobación.

> Avisame cuando termine el despliegue. Revisa cada pocos minutos.

Para una comprobación scriptable el agente configura una sonda. Para algo que necesita criterio configura un disparador de agente, formulando una pregunta de sí/no que responde en cada intervalo. También puede optar por componer el mensaje de disparo con el modelo en lugar de una plantilla fija, para que la notificación lleve un resumen real en vez de una línea enlatada. Las acciones de la herramienta `watch` son `create`, `list`, `pause`, `resume` y `cancel`.

Para mantener las cosas acotadas, puede haber como mucho 50 vigilancias activas a la vez, y Pepe rechaza una vigilancia nueva cuya condición sea idéntica a una que ya está corriendo, así que no puedes apilar duplicados por accidente. Una vigilancia también tiene un número máximo de comprobaciones; si la condición nunca se vuelve verdadera dentro de ese presupuesto, la vigilancia caduca en silencio en vez de sondear para siempre.

### Entrega al canal de origen

Una vigilancia registra su **origen**, el canal y la conversación desde los que se creó, en el momento de la creación. Cuando se dispara entrega de vuelta ahí, incluso tras un reinicio, ya sea un chat de Telegram, una sesión de terminal o WebSocket conectada, o el log de la aplicación. Si la vigilancia se creó sobre la API HTTP sin estado (que no tiene conversación a la que responder), recurre al log.

Dos garantías lo hacen fiable:

- **Como mucho una vez.** El nuevo estado de la vigilancia (normalmente "done") se guarda en disco *antes* de intentar la entrega. Si el proceso se cae entre el disparo y la entrega, no volverá a comprobar ni disparar una segunda vez. Solo se reintenta la entrega.
- **Entrega cuando sea alcanzable.** Si una vigilancia se dispara mientras su canal está desconectado (una sesión de terminal que se cortó, por ejemplo), el mensaje se retiene y se reenvía en cada tick hasta que llega. Recibes la notificación cuando vuelves, sin que la vigilancia vuelva a comprobar.

Una vigilancia pasa por un pequeño conjunto de estados a lo largo de su vida: `pending` (aún vigilando), `paused`, `done` (disparada y entregada), `expired` (agotó su presupuesto de comprobaciones) o `cancelled`.

<div class="note"><strong>Sin base de datos, sin crontab.</strong> Las tareas y las vigilancias son registros simples en <code>~/.pepe/config.json</code>, y el historial de ejecuciones de las tareas es un archivo JSONL por tarea bajo <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. No hay nada más que instalar ni mantener corriendo. Todo el programador es un temporizador dentro del proceso que arranca cuando ejecutas <code>pepe serve</code> o un gateway, y se detiene cuando los detienes.</div>
