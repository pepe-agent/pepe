---
title: Tareas programadas
description: Encarga algo a un agente para que lo haga solo, a una hora fija, sin nadie frente al teclado. Un resumen matinal, una revisión cada hora, entregado donde tú digas.
---

## Tareas recurrentes

Una tarea programada es un encargo que le das a un agente una sola vez y que, desde ese
momento, ocurre por su cuenta: "cada día laborable a las 9, resume los errores de la
noche y mándamelos". Por dentro, una tarea no es más que un prompt autosuficiente, un
horario, una zona horaria y un destino para el resultado. Cuando le toca dispararse, Pepe
ejecuta el agente sobre ese prompt en una **sesión nueva, sin historial de chat**: no
arrastra nada de conversaciones previas, así que el propio prompt tiene que contener todo
lo que hace falta para completar la ejecución (qué hacer, qué datos revisar, la ventana de
tiempo a cubrir).

<div class="note">Si el prompt de una tarea termina haciendo siempre exactamente lo mismo, pagar una llamada real al modelo en cada ejecución es gasto de más. Revisa <a href="../flows/">Flows</a>: ahí una tarea programada reproduce una secuencia de llamadas a herramientas ya probada, sin invocar al modelo en absoluto.</div>

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

Solo `--name`, `--prompt` y `--schedule` son obligatorios; todo lo demás cae en un valor
razonable por defecto:

| Opción | Qué hace | Valor por defecto |
| --- | --- | --- |
| `--agent` | Qué agente ejecuta el prompt | Tu agente por defecto |
| `--timezone` | Zona horaria IANA en la que se interpreta el horario | La zona configurada por defecto (ver más abajo) |
| `--model` | Corre esta tarea con una conexión de modelo puntual | El modelo propio del agente |
| `--deliver` | Adónde va a parar el resultado | `none` (queda registrado, no se envía a nadie) |

El repertorio completo de comandos:

```bash
pepe cron list                 # todas las tareas, con su próxima hora de ejecución
pepe cron add ...              # crea una tarea (ver arriba)
pepe cron run morning-brief    # la fuerza ahora mismo e imprime el resultado
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # historial reciente de ejecuciones
```

Cada tarea recibe un id legible sacado de su nombre (`morning-brief`); si ese id ya está
en uso, Pepe le agrega un número (`morning-brief-2`).

### Desde el panel

Arranca `pepe serve` y abre la página **Scheduled**. Ahí aparecen todas las tareas con su
próxima hora de ejecución, y las mismas acciones de la CLI están disponibles como
botones: crear una tarea con un formulario, forzar una ejecución, activar o desactivar,
editar, eliminar, y consultar el historial de una tarea sin salir de la página. El
formulario de creación cubre exactamente lo mismo que la CLI (agente, prompt, horario,
zona horaria, modelo y destino del resultado, incluida la opción "No enviar a ningún
lado"). Al escribir el horario, el panel puede traducir una frase como "cada día laborable
a las 9:30" a la expresión cron correspondiente usando un modelo configurado, y valida el
resultado antes de guardarlo.

### Expresiones de horario y zonas horarias

El horario es una expresión cron estándar de 5 campos: `minuto hora día-del-mes mes
día-de-la-semana`.

```
0 9 * * 1-5     # 09:00, lunes a viernes
*/15 * * * *    # cada 15 minutos
0 0 1 * *       # medianoche del día 1 de cada mes
30 8 * * *      # 08:30 todos los días
```

Cada tarea lleva su propia **zona horaria con nombre**, no un desfase fijo en UTC, porque
"las 9 de la mañana hora local" se mueve respecto a UTC dos veces al año por el cambio de
horario. Pepe guarda la expresión junto con un nombre de zona (`America/Sao_Paulo`,
`Europe/Berlin`) y evalúa el horario dentro de esa zona. Al cruzar un cambio de horario
hace lo razonable: salta el hueco que deja el cambio de primavera y, en el solapamiento
del otoño, se queda con el lado más tardío, de modo que un trabajo nunca se dispara dos
veces ni deja de dispararse sin que nadie lo note.

Define tu zona por defecto una vez, durante `pepe setup`; cualquier tarea que no nombre la
suya propia hereda esa. Si no hay ninguna configurada, el respaldo final es UTC.

<div class="note"><strong>Describe el horario con tus palabras.</strong> Escribir una expresión cron a mano es fácil de arruinar. Tanto el formulario del panel como un agente por chat pueden convertir una frase como "cada día laborable a las 9:30" en la expresión que corresponde. Toda expresión generada se valida antes de guardarse, así que jamás queda almacenada una inválida.</div>

### Adónde va el resultado

El destino que fijes en `deliver` decide qué pasa con la salida de cada ejecución:

- `telegram:<chat_id>` la manda a ese chat de Telegram. El mensaje lleva el nombre de la
  tarea como prefijo, para que un chat que recibe varias tareas distintas pueda
  distinguirlas.
- `none` no la manda a ningún lado: la ejecución ocurre igual y queda registrada en el
  historial. Útil para tareas cuyo propósito es un efecto secundario (escribir un
  archivo, llamar a una herramienta) y nada más.
- Cualquier otro valor (incluido `log`) escribe la salida en el log de la aplicación.

Sin importar el destino elegido, cada ejecución queda además anotada en el archivo de
historial propio de esa tarea, así que siempre puedes volver a leer qué pasó.

### El pulso por minuto y la recuperación tras una caída

El programador late cada 30 segundos, a propósito por debajo del minuto, para que una
mínima deriva del reloj nunca le haga perderse uno. En cada latido revisa todas las
tareas activas y dispara las que coinciden con el minuto actual, ya en la zona horaria de
esa tarea. Un control por tarea garantiza que un trabajo se dispare **como máximo una vez
por minuto**, aunque el latido en sí sea más frecuente.

Este pulso vive dentro del proceso de la aplicación, así que solo corre mientras `pepe
serve` o `pepe gateway` están arriba, nunca durante un comando de una sola ejecución. Cada
tarea que le toca correr lo hace en su propio proceso, de modo que varias tareas que caen
en el mismo minuto se disparan a la vez y ninguna tarea lenta bloquea a las demás. Las
definiciones de las tareas en sí viven en `~/.pepe/config.json`, bajo la clave `"crons"`.

Si el proceso estaba caído justo cuando a una tarea le tocaba dispararse, Pepe hace una
**recuperación** acotada al volver a levantarse: si detecta que se saltó un turno
programado sin ejecutarlo, dispara ese trabajo una única vez, siempre que todavía esté
dentro de una ventana de gracia (la mitad del período de la tarea, entre 2 minutos y 2
horas como límites). Esa recuperación queda anclada al turno perdido específico, así que
un solo reinicio nunca duplica el disparo. Si el proceso estuvo caído mucho más tiempo que
esa ventana de gracia, la tarea simplemente retoma en su siguiente turno normal, sin
intentar repetir algo ya vencido.

### Una tarea no se pisa a sí misma

Si la ejecución anterior de una tarea **todavía sigue corriendo** cuando llega el momento
de la siguiente, esa nueva ejecución se **salta**, y el salto queda anotado en el
historial.

Se salta en lugar de acumularse porque, aquí, una tarea no es un script idempotente:
es **un turno de agente**. Cuesta una llamada al modelo, produce efectos secundarios (un
mensaje entregado, un archivo escrito) y todas las ejecuciones de una misma tarea
comparten un único espacio de trabajo del agente. Un trabajo que tarda siete minutos con
una programación cada cinco terminaría acumulándose: dos ejecuciones, luego tres, luego
cuatro, cada una facturada aparte, el informe entregado por duplicado, y dos ejecuciones
escribiendo una encima de la otra. Te enterarías por la factura, no por el aviso.

Y el salto nunca ocurre en silencio: queda como una entrada fallida en el historial, con
el motivo explicado:

> ⏭️ skipped: the previous run was still going. This job takes longer than its own schedule allows.

Esa entrada es justamente el punto. Sin ella, el trabajo simplemente dejaría de hacer lo
suyo, puntualmente y sin aviso, y la primera pista de que algo fallaba sería notar que ya
no se estaba haciendo.

```bash
pepe cron add --name "digest" --prompt "..." --schedule "*/5 * * * *" --overlap
```

`--overlap` (o `"overlap": true` en la configuración) deja que corra de todos modos, para
el caso puntual en que la concurrencia sea justo lo que buscas.

### Historial de ejecuciones

Cada disparo, sea del temporizador, de un `pepe cron run` forzado, de un botón del panel o
de un chat, agrega una línea al archivo de historial de esa tarea
(`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Cada línea guarda la marca de tiempo, el
origen, si terminó bien o mal, y la salida (recortada).

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

El campo `source` de cada línea puede ser `scheduler` (lo disparó el temporizador),
`manual` (lo forzaste tú desde la CLI o el panel) o `agent` (lo forzó un chat).

### Desde el chat

Si tiene la herramienta `schedule_task` en su conjunto de herramientas, un agente puede
crear y administrar sus propias tareas programadas en plena conversación, ya sea en el
chat de la CLI o en cualquier canal conectado. Basta con pedirlo en lenguaje natural:

> Cada día laborable a las 8:30 de mi hora, revisa la página de estado y avísame aquí si
> algo está degradado.

Como el agente conoce la hora local en curso (su system prompt viene anclado a ella), una
frase como "mañana a las 8:30" apunta al turno correcto en vez de irse a UTC por error. El
propio agente redacta el prompt completo y autosuficiente, elige la expresión cron y, por
defecto, entrega el resultado al mismo chat desde el que se lo pediste.

La herramienta `schedule_task` admite las mismas acciones que la CLI: `create`, `list`,
`run` (forzar ahora para previsualizar), `enable`, `disable`, `remove` e `history`.

#### La doble puerta de entrada

Crear trabajo programado desde el chat está protegido dos veces a propósito, porque una
tarea así queda corriendo sola más adelante, sin supervisión:

1. **La herramienta tiene que estar habilitada para ese agente.** Un agente nuevo trae
   `schedule_task` por defecto, como cualquier otra herramienta; quítasela de su lista si
   no debería poder programar nada en absoluto.
2. **Cada creación te lo pregunta igual.** `schedule_task` es una herramienta con
   permiso: salvo que ya la hayas preaprobado, el runtime te pide autorizar esa llamada
   concreta antes de que surta efecto. Cada canal muestra ese aviso a su manera (botones
   en línea en Telegram, un menú de flechas en la terminal), y puedes responder solo por
   esta vez, por el resto de la sesión, siempre (queda recordado para ese agente), o
   simplemente negarte.

De modo que ninguna tarea aparece a tus espaldas: la capacidad se puede retirar agente por
agente, y encima de eso, cada tarea concreta sigue necesitando tu autorización.
