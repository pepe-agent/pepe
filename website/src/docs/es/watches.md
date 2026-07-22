---
title: Vigilancias
description: Crea vigilancias duraderas que avisan una sola vez cuando una condición se cumple.
---

## Vigilancias

Una vigilancia responde a una pregunta distinta: no "haz esto según el reloj" sino "mantén un ojo en algo y avísame en el momento en que pase". Una vigilancia recomprueba una condición con un temporizador y te notifica **una vez** cuando se vuelve verdadera, y luego se detiene. Es duradera: sobrevive a un reinicio y al cierre de la sesión que la creó, y siempre responde en el canal desde el que se creó.

### Disparadores por sonda y por agente

La parte barata de una vigilancia es el **disparador**, que se ejecuta en cada intervalo. Solo cuando el disparador se activa se ejecuta la notificación (posiblemente costosa), una vez. Hay dos tipos de disparador:

- Una **sonda** ejecuta un comando de shell y no cuesta tokens por comprobación. El éxito es el código de salida 0 por defecto, o puedes exigir que aparezca una cadena en la salida del comando. Usa una sonda siempre que la condición sea scriptable (una URL está accesible, un trabajo escribió un archivo, un log contiene una línea).
- Un disparador de **agente** le vuelve a preguntar al agente una pregunta de sí/no en cada intervalo, una llamada al modelo por comprobación. Úsalo solo cuando decidir si la condición se cumple requiere verdadero criterio.

Como las comprobaciones de agente cuestan tokens, su intervalo mínimo es más alto: 300 segundos para disparadores de agente, 30 segundos para sondas. El intervalo por defecto es de 120 segundos.

### Qué envía cuando se dispara

Cuando el disparador por fin pasa, una vigilancia entrega un mensaje. Ese mensaje es una **plantilla** fija (un texto que defines por adelantado, sin llamada al modelo) o lo **compone el agente** en el momento del disparo (una llamada al modelo, una vez) para que pueda incluir detalle fresco, como un resumen de lo que realmente pasó.

La combinación que vale la pena conocer es una sonda gratuita que controla un mensaje compuesto por el agente. El sondeo con `curl` no cuesta nada, y solo se le pide al modelo que escriba el resumen en el momento en que la condición se cumple.

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

> Avísame cuando termine el despliegue. Revisa cada pocos minutos.

Para una comprobación scriptable el agente configura una sonda. Para algo que necesita criterio configura un disparador de agente, formulando una pregunta de sí/no que responde en cada intervalo. También puede optar por componer el mensaje de disparo con el modelo en lugar de una plantilla fija, para que la notificación lleve un resumen real en vez de una línea enlatada. Las acciones de la herramienta `watch` son `create`, `list`, `pause`, `resume` y `cancel`.

Para mantener las cosas acotadas, puede haber como mucho 50 vigilancias activas a la vez, y Pepe rechaza una vigilancia nueva cuya condición sea idéntica a una que ya está activa, así que no puedes apilar duplicados por accidente. Una vigilancia también tiene un número máximo de comprobaciones; si la condición nunca se vuelve verdadera dentro de ese presupuesto, la vigilancia caduca en silencio en vez de sondear para siempre.

### Entrega al canal de origen

Una vigilancia registra su **origen**, el canal y la conversación desde los que se creó, en el momento de la creación. Cuando se dispara entrega de vuelta ahí, incluso tras un reinicio, ya sea un chat de Telegram (un envío directo), una sesión de terminal o WebSocket conectada, o el log de la aplicación. En un WebSocket la notificación llega como un evento `"watch"` en el canal; pasa un `session` estable al unirte y la recibirás incluso tras reconectar, en vez de solo en el socket que casualmente creó la vigilancia. En `pepe chat` se imprime directamente en la consola. Si la vigilancia se creó sobre la API HTTP sin estado (que no tiene conversación a la que responder), recurre al log.

Dos garantías lo hacen fiable:

- **Como mucho una vez.** El nuevo estado de la vigilancia (normalmente "done") se guarda en disco *antes* de intentar la entrega. Si el proceso se cae entre el disparo y la entrega, no volverá a comprobar ni disparar una segunda vez. Solo se reintenta la entrega.
- **Entrega cuando sea alcanzable.** Si una vigilancia se dispara mientras su canal está desconectado (una sesión de terminal que se cortó, por ejemplo), el mensaje se retiene y se reenvía en cada tick hasta que llega. Recibes la notificación cuando vuelves, sin que la vigilancia vuelva a comprobar.

Una vigilancia pasa por un pequeño conjunto de estados a lo largo de su vida: `pending` (aún vigilando), `paused`, `done` (disparada y entregada), `expired` (agotó su presupuesto de comprobaciones) o `cancelled`.

<div class="note"><strong>Sin base de datos que instalar, sin crontab.</strong> Las tareas programadas siguen siendo registros simples en <code>~/.pepe/config.json</code> (bajo <code>"crons"</code>), con un archivo JSONL de historial de ejecuciones por tarea bajo <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Las vigilancias viven en el mismo pequeño archivo SQLite embebido que los compromisos, no algo que tengas que instalar o administrar tú mismo. De cualquier forma, no hay nada más que mantener en marcha: todo el programador es un temporizador dentro del proceso, que se ejecuta en cualquier superficie de vida larga que esté en pie: <code>pepe serve</code>, un gateway o un <code>pepe chat</code> interactivo, y se detiene cuando detienes la superficie. Ejecuta solo una a la vez contra la misma configuración: dos harían tick las dos, y una vigilancia avisaría dos veces.</div>
